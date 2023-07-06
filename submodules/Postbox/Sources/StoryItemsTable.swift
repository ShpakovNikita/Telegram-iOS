import Foundation

public final class StoryItemsTableEntry: Equatable {
    public let value: CodableEntry
    public let id: Int32
    public let expirationTimestamp: Int32?
    
    public init(
        value: CodableEntry,
        id: Int32,
        expirationTimestamp: Int32?
    ) {
        self.value = value
        self.id = id
        self.expirationTimestamp = expirationTimestamp
    }
    
    public static func ==(lhs: StoryItemsTableEntry, rhs: StoryItemsTableEntry) -> Bool {
        if lhs === rhs {
            return true
        }
        if lhs.id != rhs.id {
            return false
        }
        if lhs.value != rhs.value {
            return false
        }
        if lhs.expirationTimestamp != rhs.expirationTimestamp {
            return false
        }
        return true
    }
}

final class StoryTopItemsTable: Table {
    struct Entry {
        var id: Int32
        var isExact: Bool
    }
    
    enum Event {
        case replace(peerId: PeerId)
    }
    
    private struct Key: Hashable {
        var peerId: PeerId
    }
    
    static func tableSpec(_ id: Int32) -> ValueBoxTable {
        return ValueBoxTable(id: id, keyType: .binary, compactValuesOnCreation: false)
    }
    
    private let sharedKey = ValueBoxKey(length: 8 + 4)
    
    private func key(_ key: Key) -> ValueBoxKey {
        self.sharedKey.setInt64(0, value: key.peerId.toInt64())
        return self.sharedKey
    }
    
    public func get(peerId: PeerId) -> Entry? {
        if let value = self.valueBox.get(self.table, key: self.key(Key(peerId: peerId))) {
            let buffer = ReadBuffer(memoryBufferNoCopy: value)
            var version: UInt8 = 0
            buffer.read(&version, offset: 0, length: 1)
            if version != 100 {
                return nil
            }
            var maxId: Int32 = 0
            buffer.read(&maxId, offset: 0, length: 4)
            var isExact: Int8 = 0
            buffer.read(&isExact, offset: 0, length: 1)
            
            return Entry(id: maxId, isExact: isExact != 0)
        } else {
            return nil
        }
    }
    
    public func set(peerId: PeerId, entry: Entry?, events: inout [Event]) {
        if let entry = entry {
            let buffer = WriteBuffer()
            
            var version: UInt8 = 100
            buffer.write(&version, length: 1)
            var maxId = entry.id
            buffer.write(&maxId, length: 4)
            var isExact: Int8 = entry.isExact ? 1 : 0
            buffer.write(&isExact, length: 1)
            
            self.valueBox.set(self.table, key: self.key(Key(peerId: peerId)), value: buffer.readBufferNoCopy())
        } else {
            self.valueBox.remove(self.table, key: self.key(Key(peerId: peerId)), secure: true)
        }
    }
    
    override func clearMemoryCache() {
    }
    
    override func beforeCommit() {
    }
}


final class StoryItemsTable: Table {
    enum Event {
        case replace(peerId: PeerId)
    }
    
    private struct Key: Hashable {
        var peerId: PeerId
        var id: Int32
    }
    
    static func tableSpec(_ id: Int32) -> ValueBoxTable {
        return ValueBoxTable(id: id, keyType: .binary, compactValuesOnCreation: false)
    }
    
    private let sharedKey = ValueBoxKey(length: 8 + 4)
    
    private func key(_ key: Key) -> ValueBoxKey {
        self.sharedKey.setInt64(0, value: key.peerId.toInt64())
        self.sharedKey.setInt32(8, value: key.id)
        return self.sharedKey
    }
    
    private func lowerBound(peerId: PeerId) -> ValueBoxKey {
        let key = ValueBoxKey(length: 8)
        key.setInt64(0, value: peerId.toInt64())
        return key
    }
    
    private func upperBound(peerId: PeerId) -> ValueBoxKey {
        let key = ValueBoxKey(length: 8)
        key.setInt64(0, value: peerId.toInt64())
        return key.successor
    }
    
    public func getStats(peerId: PeerId, maxSeenId: Int32) -> (total: Int, unseen: Int) {
        var total = 0
        var unseen = 0
        
        self.valueBox.range(self.table, start: self.lowerBound(peerId: peerId), end: self.upperBound(peerId: peerId), keys: { key in
            let id = key.getInt32(8)
            
            total += 1
            if id > maxSeenId {
                unseen += 1
            }
            
            return true
        }, limit: 10000)
        
        return (total, unseen)
    }
    
    public func get(peerId: PeerId) -> [StoryItemsTableEntry] {
        var result: [StoryItemsTableEntry] = []

        self.valueBox.range(self.table, start: self.lowerBound(peerId: peerId), end: self.upperBound(peerId: peerId), values: { key, value in
            let id = key.getInt32(8)
            
            let entry: CodableEntry
            var expirationTimestamp: Int32?
            
            let readBuffer = ReadBuffer(data: value.makeData())
            var magic: UInt32 = 0
            readBuffer.read(&magic, offset: 0, length: 4)
            if magic == 0xabcd1234 {
                var length: Int32 = 0
                readBuffer.read(&length, offset: 0, length: 4)
                if length > 0 && readBuffer.offset + Int(length) <= readBuffer.length {
                    entry = CodableEntry(data: readBuffer.readData(length: Int(length)))
                    if readBuffer.offset + 4 <= readBuffer.length {
                        var expirationTimestampValue: Int32 = 0
                        readBuffer.read(&expirationTimestampValue, offset: 0, length: 4)
                        expirationTimestamp = expirationTimestampValue
                    }
                } else {
                    entry = CodableEntry(data: Data())
                }
            } else {
                entry = CodableEntry(data: value.makeData())
            }
            
            result.append(StoryItemsTableEntry(value: entry, id: id, expirationTimestamp: expirationTimestamp))
            
            return true
        }, limit: 10000)
        
        return result
    }
    
    func getExpiredIds(belowTimestamp: Int32) -> [StoryId] {
        var ids: [StoryId] = []
        
        self.valueBox.scan(self.table, values: { key, value in
            let peerId = PeerId(key.getInt64(0))
            let id = key.getInt32(8)
            var expirationTimestamp: Int32?
            
            let readBuffer = ReadBuffer(data: value.makeData())
            var magic: UInt32 = 0
            readBuffer.read(&magic, offset: 0, length: 4)
            if magic == 0xabcd1234 {
                var length: Int32 = 0
                readBuffer.read(&length, offset: 0, length: 4)
                if length > 0 && readBuffer.offset + Int(length) <= readBuffer.length {
                    readBuffer.skip(Int(length))
                    if readBuffer.offset + 4 <= readBuffer.length {
                        var expirationTimestampValue: Int32 = 0
                        readBuffer.read(&expirationTimestampValue, offset: 0, length: 4)
                        expirationTimestamp = expirationTimestampValue
                    }
                }
            }
            
            if let expirationTimestamp = expirationTimestamp {
                if expirationTimestamp <= belowTimestamp {
                    ids.append(StoryId(peerId: peerId, id: id))
                }
            }
            
            return true
        })
        
        return ids
    }
    
    func getMinExpirationTimestamp() -> (StoryId, Int32)? {
        var minValue: (StoryId, Int32)?
        self.valueBox.scan(self.table, values: { key, value in
            let peerId = PeerId(key.getInt64(0))
            let id = key.getInt32(8)
            var expirationTimestamp: Int32?
            
            let readBuffer = ReadBuffer(data: value.makeData())
            var magic: UInt32 = 0
            readBuffer.read(&magic, offset: 0, length: 4)
            if magic == 0xabcd1234 {
                var length: Int32 = 0
                readBuffer.read(&length, offset: 0, length: 4)
                if length > 0 && readBuffer.offset + Int(length) <= readBuffer.length {
                    readBuffer.skip(Int(length))
                    if readBuffer.offset + 4 <= readBuffer.length {
                        var expirationTimestampValue: Int32 = 0
                        readBuffer.read(&expirationTimestampValue, offset: 0, length: 4)
                        expirationTimestamp = expirationTimestampValue
                    }
                }
            }
            
            if let expirationTimestamp = expirationTimestamp {
                if let (_, currentTimestamp) = minValue {
                    if expirationTimestamp < currentTimestamp {
                        minValue = (StoryId(peerId: peerId, id: id), expirationTimestamp)
                    }
                } else {
                    minValue = (StoryId(peerId: peerId, id: id), expirationTimestamp)
                }
            }
            
            return true
        })
        return minValue
    }
    
    public func replace(peerId: PeerId, entries: [StoryItemsTableEntry], topItemTable: StoryTopItemsTable, events: inout [Event], topItemEvents: inout [StoryTopItemsTable.Event]) {
        var previousKeys: [ValueBoxKey] = []
        self.valueBox.range(self.table, start: self.lowerBound(peerId: peerId), end: self.upperBound(peerId: peerId), keys: { key in
            previousKeys.append(key)
            
            return true
        }, limit: 10000)
        for key in previousKeys {
            self.valueBox.remove(self.table, key: key, secure: true)
        }
        
        let buffer = WriteBuffer()
        for entry in entries {
            buffer.reset()
            
            var magic: UInt32 = 0xabcd1234
            buffer.write(&magic, length: 4)
            
            var length: Int32 = Int32(entry.value.data.count)
            buffer.write(&length, length: 4)
            buffer.write(entry.value.data)
            
            if let expirationTimestamp = entry.expirationTimestamp {
                var expirationTimestampValue: Int32 = expirationTimestamp
                buffer.write(&expirationTimestampValue, length: 4)
            }
            
            self.valueBox.set(self.table, key: self.key(Key(peerId: peerId, id: entry.id)), value: buffer.readBufferNoCopy())
        }
        
        events.append(.replace(peerId: peerId))
        
        topItemTable.set(peerId: peerId, entry: StoryTopItemsTable.Entry(id: entries.last?.id ?? 0, isExact: true), events: &topItemEvents)
    }
    
    override func clearMemoryCache() {
    }
    
    override func beforeCommit() {
    }
}
