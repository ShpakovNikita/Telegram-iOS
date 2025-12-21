load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load(
    "@build_bazel_rules_apple//apple:resources.bzl",
    "apple_metal_library",
    "apple_resource_bundle",
    "apple_resource_group",
)
load("//build-system/bazel-utils:plist_fragment.bzl",
    "plist_fragment",
)

apple_metal_library(
    name = "GlassBackgroundComponentMetalLibrary",
    srcs = glob([
        "MetalResources/**/*.metal",
    ]),
    copts = [
        "-frecord-sources",
        "-gline-tables-only",
    ],
)

plist_fragment(
    name = "GlassBackgroundComponentBundleInfoPlist",
    extension = "plist",
    template =
    """
    <key>CFBundleIdentifier</key>
    <string>org.telegram.GlassBackgroundComponent</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleName</key>
    <string>GlassBackgroundComponent</string>
    """
)

apple_resource_bundle(
    name = "GlassBackgroundComponentBundle",
    infoplists = [
        ":GlassBackgroundComponentBundleInfoPlist",
    ],
    resources = [
        ":GlassBackgroundComponentMetalLibrary",
    ],
)

swift_library(
    name = "GlassBackgroundComponent",
    module_name = "GlassBackgroundComponent",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/Display",
        "//submodules/ComponentFlow",
        "//submodules/Components/ComponentDisplayAdapters",
        "//submodules/UIKitRuntimeUtils",
        "//submodules/AppBundle",
    ],
    data = [
        ":GlassBackgroundComponentBundle",
    ],
    visibility = [
        "//visibility:public",
    ],
)
