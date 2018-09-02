import Foundation
#if os(macOS)
import PostboxMac
import SwiftSignalKitMac
#else
import Postbox
import SwiftSignalKit
#endif

private final class ContactSyncOperation {
    let id: Int32
    var isRunning: Bool = false
    let content: ContactSyncOperationContent
    let disposable = DisposableSet()
    
    init(id: Int32, content: ContactSyncOperationContent) {
        self.id = id
        self.content = content
    }
}

private enum ContactSyncOperationContent {
    case sync(importableContacts: [DeviceContactNormalizedPhoneNumber: ImportableDeviceContactData]?)
    case updateIsContact(peerId: PeerId, isContact: Bool)
}

private final class ContactSyncManagerImpl {
    private let queue: Queue
    private let postbox: Postbox
    private let network: Network
    private let stateManager: AccountStateManager
    private var nextId: Int32 = 0
    private var operations: [ContactSyncOperation] = []
    
    private var reimportAttempts: [TelegramDeviceContactImportIdentifier: Double] = [:]
    
    private let importableContactsDisposable = MetaDisposable()
    
    init(queue: Queue, postbox: Postbox, network: Network, stateManager: AccountStateManager) {
        self.queue = queue
        self.postbox = postbox
        self.network = network
        self.stateManager = stateManager
    }
    
    deinit {
        self.importableContactsDisposable.dispose()
    }
    
    func beginSync(importableContacts: Signal<[DeviceContactNormalizedPhoneNumber: ImportableDeviceContactData], NoError>) {
        self.importableContactsDisposable.set((importableContacts
        |> deliverOn(self.queue)).start(next: { [weak self] importableContacts in
            guard let strongSelf = self else {
                return
            }
            strongSelf.addOperation(.sync(importableContacts: importableContacts))
        }))
    }
    
    func addOperation(_ content: ContactSyncOperationContent) {
        let id = self.nextId
        self.nextId += 1
        let operation = ContactSyncOperation(id: id, content: content)
        switch content {
            case .sync:
                for i in (0 ..< self.operations.count).reversed() {
                    if case .sync = self.operations[i].content {
                        if !self.operations[i].isRunning {
                            self.operations.remove(at: i)
                        }
                    }
                }
            default:
                break
        }
        self.operations.append(operation)
        self.updateOperations()
    }
    
    func updateOperations() {
        if let first = self.operations.first, !first.isRunning {
            first.isRunning = true
            let id = first.id
            let queue = self.queue
            self.startOperation(first.content, disposable: first.disposable, completion: { [weak self] in
                queue.async {
                    guard let strongSelf = self else {
                        return
                    }
                    if let currentFirst = strongSelf.operations.first, currentFirst.id == id {
                        strongSelf.operations.remove(at: 0)
                        strongSelf.updateOperations()
                    } else {
                        assertionFailure()
                    }
                }
            })
        }
    }
    
    func startOperation(_ operation: ContactSyncOperationContent, disposable: DisposableSet, completion: @escaping () -> Void) {
        switch operation {
            case let .sync(importableContacts):
                let importSignal: Signal<PushDeviceContactsResult, NoError>
                if let importableContacts = importableContacts {
                    importSignal = pushDeviceContacts(postbox: self.postbox, network: self.network, importableContacts: importableContacts, reimportAttempts: self.reimportAttempts)
                } else {
                    importSignal = .single(PushDeviceContactsResult(addedReimportAttempts: [:]))
                }
                disposable.add((self.stateManager.pollStateUpdateCompletion()
                |> mapToSignal { _ -> Signal<PushDeviceContactsResult, NoError> in
                    return .complete()
                }
                |> then(
                    syncContactsOnce(network: self.network, postbox: self.postbox)
                    |> mapToSignal { _ -> Signal<PushDeviceContactsResult, NoError> in
                        return .complete()
                    }
                    |> then(importSignal)
                )
                |> deliverOn(self.queue)).start(next: { [weak self] result in
                    guard let strongSelf = self else {
                        return
                    }
                    for (identifier, timestamp) in result.addedReimportAttempts {
                        strongSelf.reimportAttempts[identifier] = timestamp
                    }
                    
                    completion()
                }))
            case let .updateIsContact(peerId, isContact):
                disposable.add((self.postbox.transaction { transaction -> Void in
                    if transaction.isPeerContact(peerId: peerId) != isContact {
                        var contactPeerIds = transaction.getContactPeerIds()
                        if isContact {
                            contactPeerIds.insert(peerId)
                        } else {
                            contactPeerIds.remove(peerId)
                        }
                        transaction.replaceContactPeerIds(contactPeerIds)
                    }
                }
                |> deliverOnMainQueue).start(completed: {
                    completion()
                }))
        }
    }
}

private struct PushDeviceContactsResult {
    let addedReimportAttempts: [TelegramDeviceContactImportIdentifier: Double]
}

private func pushDeviceContacts(postbox: Postbox, network: Network, importableContacts: [DeviceContactNormalizedPhoneNumber: ImportableDeviceContactData], reimportAttempts: [TelegramDeviceContactImportIdentifier: Double]) -> Signal<PushDeviceContactsResult, NoError> {
    return postbox.transaction { transaction -> Signal<PushDeviceContactsResult, NoError> in
        var noLongerImportedIdentifiers = Set<TelegramDeviceContactImportIdentifier>()
        var updatedDataIdentifiers = Set<TelegramDeviceContactImportIdentifier>()
        var addedIdentifiers = Set<TelegramDeviceContactImportIdentifier>()
        var retryLaterIdentifiers = Set<TelegramDeviceContactImportIdentifier>()
        
        addedIdentifiers.formUnion(importableContacts.keys.map(TelegramDeviceContactImportIdentifier.phoneNumber))
        transaction.enumerateDeviceContactImportInfoItems({ key, value in
            if let identifier = TelegramDeviceContactImportIdentifier(key: key) {
                addedIdentifiers.remove(identifier)
                switch identifier {
                    case let .phoneNumber(number):
                        if let updatedData = importableContacts[number] {
                            if let value = value as? TelegramDeviceContactImportedData {
                                switch value {
                                    case let .imported(imported):
                                        if imported.data != updatedData {
                                           updatedDataIdentifiers.insert(identifier)
                                        }
                                    case .retryLater:
                                        retryLaterIdentifiers.insert(identifier)
                                }
                            } else {
                                assertionFailure()
                            }
                        } else {
                            noLongerImportedIdentifiers.insert(identifier)
                        }
                }
            } else {
                assertionFailure()
            }
            return true
        })
        
        for identifier in noLongerImportedIdentifiers {
            transaction.setDeviceContactImportInfo(identifier.key, value: nil)
        }
        
        var orderedPushIdentifiers: [TelegramDeviceContactImportIdentifier] = []
        orderedPushIdentifiers.append(contentsOf: addedIdentifiers.sorted())
        orderedPushIdentifiers.append(contentsOf: updatedDataIdentifiers.sorted())
        orderedPushIdentifiers.append(contentsOf: retryLaterIdentifiers.sorted())
        
        var currentContactDetails: [TelegramDeviceContactImportIdentifier: TelegramUser] = [:]
        for peerId in transaction.getContactPeerIds() {
            if let user = transaction.getPeer(peerId) as? TelegramUser, let phone = user.phone, !phone.isEmpty {
                currentContactDetails[.phoneNumber(DeviceContactNormalizedPhoneNumber(rawValue: formatPhoneNumber(phone)))] = user
            }
        }
        
        let timestamp = CFAbsoluteTimeGetCurrent()
        outer: for i in (0 ..< orderedPushIdentifiers.count).reversed() {
            if let user = currentContactDetails[orderedPushIdentifiers[i]], case let .phoneNumber(number) = orderedPushIdentifiers[i], let data = importableContacts[number] {
                if (user.firstName ?? "") == data.firstName && (user.lastName ?? "") == data.lastName {
                    transaction.setDeviceContactImportInfo(orderedPushIdentifiers[i].key, value: TelegramDeviceContactImportedData.imported(data: data, importedByCount: 0))
                    orderedPushIdentifiers.remove(at: i)
                    continue outer
                }
            }
            
            if let attemptTimestamp = reimportAttempts[orderedPushIdentifiers[i]], attemptTimestamp + 60.0 * 60.0 * 24.0 > timestamp {
                orderedPushIdentifiers.remove(at: i)
            }
        }
        
        var preparedContactData: [(DeviceContactNormalizedPhoneNumber, ImportableDeviceContactData)] = []
        for identifier in orderedPushIdentifiers {
            if case let .phoneNumber(number) = identifier, let value = importableContacts[number] {
                preparedContactData.append((number, value))
            }
        }
        
        return pushDeviceContactData(postbox: postbox, network: network, contacts: preparedContactData)
    }
    |> switchToLatest
}

private let importBatchCount: Int = 100

private func pushDeviceContactData(postbox: Postbox, network: Network, contacts: [(DeviceContactNormalizedPhoneNumber, ImportableDeviceContactData)]) -> Signal<PushDeviceContactsResult, NoError> {
    var batches: Signal<PushDeviceContactsResult, NoError> = .single(PushDeviceContactsResult(addedReimportAttempts: [:]))
    for s in stride(from: 0, to: contacts.count, by: importBatchCount) {
        let batch = Array(contacts[s ..< min(s + importBatchCount, contacts.count)])
        batches = batches
        |> mapToSignal { intermediateResult -> Signal<PushDeviceContactsResult, NoError> in
            return network.request(Api.functions.contacts.importContacts(contacts: zip(0 ..< batch.count, batch).map { index, item -> Api.InputContact in
                return .inputPhoneContact(clientId: Int64(index), phone: item.0.rawValue, firstName: item.1.firstName, lastName: item.1.lastName)
            }))
            |> map(Optional.init)
            |> `catch` { _ -> Signal<Api.contacts.ImportedContacts?, NoError> in
                return .single(nil)
            }
            |> mapToSignal { result -> Signal<PushDeviceContactsResult, NoError> in
                return postbox.transaction { transaction -> PushDeviceContactsResult in
                    var addedReimportAttempts: [TelegramDeviceContactImportIdentifier: Double] = intermediateResult.addedReimportAttempts
                    if let result = result {
                        var addedContactPeerIds = Set<PeerId>()
                        var retryIndices = Set<Int>()
                        var importedCounts: [Int: Int32] = [:]
                        switch result {
                            case let .importedContacts(imported, popularInvites, retryContacts, users):
                                let peers = users.map { TelegramUser(user: $0) as Peer }
                                updatePeers(transaction: transaction, peers: peers, update: { _, updated in
                                    return updated
                                })
                                for item in imported {
                                    switch item {
                                        case let .importedContact(userId, _):
                                            addedContactPeerIds.insert(PeerId(namespace: Namespaces.Peer.CloudUser, id: userId))
                                    }
                                }
                                for item in retryContacts {
                                    retryIndices.insert(Int(item))
                                }
                                for item in popularInvites {
                                    switch item {
                                        case let .popularContact(clientId, importers):
                                            importedCounts[Int(clientId)] = importers
                                    }
                                }
                        }
                        let timestamp = CFAbsoluteTimeGetCurrent()
                        for i in 0 ..< batch.count {
                            let importedData: TelegramDeviceContactImportedData
                            if retryIndices.contains(i) {
                                importedData = .retryLater
                                addedReimportAttempts[.phoneNumber(batch[i].0)] = timestamp
                            } else {
                                importedData = .imported(data: batch[i].1, importedByCount: importedCounts[i] ?? 0)
                            }
                            transaction.setDeviceContactImportInfo(TelegramDeviceContactImportIdentifier.phoneNumber(batch[i].0).key, value: importedData)
                        }
                        var contactPeerIds = transaction.getContactPeerIds()
                        contactPeerIds.formUnion(addedContactPeerIds)
                        transaction.replaceContactPeerIds(contactPeerIds)
                    } else {
                        let timestamp = CFAbsoluteTimeGetCurrent()
                        for (number, _) in batch {
                            addedReimportAttempts[.phoneNumber(number)] = timestamp
                            transaction.setDeviceContactImportInfo(TelegramDeviceContactImportIdentifier.phoneNumber(number).key, value: TelegramDeviceContactImportedData.retryLater)
                        }
                    }
                    
                    return PushDeviceContactsResult(addedReimportAttempts: addedReimportAttempts)
                }
            }
        }
    }
    return batches
}

final class ContactSyncManager {
    private let queue = Queue()
    private let impl: QueueLocalObject<ContactSyncManagerImpl>
    
    init(postbox: Postbox, network: Network, stateManager: AccountStateManager) {
        let queue = self.queue
        self.impl = QueueLocalObject(queue: queue, generate: {
            return ContactSyncManagerImpl(queue: queue, postbox: postbox, network: network, stateManager: stateManager)
        })
    }
    
    func beginSync(importableContacts: Signal<[DeviceContactNormalizedPhoneNumber: ImportableDeviceContactData], NoError>) {
        self.impl.with { impl in
            impl.beginSync(importableContacts: importableContacts)
        }
    }
}
