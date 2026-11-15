import Foundation

private typealias StatFS = statfs

/// Capacity of one mounted file system.
public struct MountedVolumeSample: Sendable, Equatable {
    /// Device node as reported by `getfsstat`, e.g. `/dev/disk9s1`.
    public var device: String
    public var totalBytes: Int64
    public var usedBytes: Int64

    public init(device: String, totalBytes: Int64, usedBytes: Int64) {
        self.device = device
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
    }

    public var deviceIdentifier: String {
        device.hasPrefix("/dev/") ? String(device.dropFirst("/dev/".count)) : device
    }
}

/// Determines how much capacity the monitored disks currently use.
///
/// The probe is deliberately cheap: it reuses the `diskutil list -plist` output that is
/// already collected for the inventory and asks the kernel for the mounted file systems
/// with a single `getfsstat` syscall. No additional CLI process is started and no file
/// system content is scanned (`du`/`df` are not used), so even standby disks stay asleep.
public enum StorageUsageProbe {
    /// One `getfsstat` call with `MNT_NOWAIT`: no disk I/O, no process.
    public static func currentMountSamples() -> [MountedVolumeSample] {
        var count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [] }

        // `statfs` is both the C struct and the syscall; the alias keeps them apart.
        var buffer = [StatFS](repeating: StatFS(), count: Int(count))
        let bufferSize = Int32(MemoryLayout<StatFS>.size * buffer.count)
        count = getfsstat(&buffer, bufferSize, MNT_NOWAIT)
        guard count > 0 else { return [] }

        var samples: [MountedVolumeSample] = []
        samples.reserveCapacity(Int(count))

        for index in 0..<Int(count) {
            var entry = buffer[index]
            let device = withUnsafeBytes(of: &entry.f_mntfromname) { raw -> String in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return "" }
                return String(cString: base)
            }
            guard device.hasPrefix("/dev/") else { continue }

            let blockSize = Int64(entry.f_bsize)
            let totalBytes = Int64(entry.f_blocks) * blockSize
            let usedBytes = (Int64(entry.f_blocks) - Int64(entry.f_bfree)) * blockSize
            guard blockSize > 0, totalBytes > 0 else { continue }

            samples.append(
                MountedVolumeSample(
                    device: device,
                    totalBytes: totalBytes,
                    usedBytes: max(0, usedBytes)
                )
            )
        }

        return samples
    }

    /// Maps whole disk BSD names (`disk0`, `disk8`, …) to their current usage.
    ///
    /// - Parameters:
    ///   - allDisksAndPartitions: The `AllDisksAndPartitions` array of `diskutil list -plist`.
    ///   - mounts: Mounted file systems, usually from `currentMountSamples()`.
    public static func usages(
        allDisksAndPartitions: [[String: Any]],
        mounts: [MountedVolumeSample]
    ) -> [String: StorageUsage] {
        let mapping = buildMapping(allDisksAndPartitions)

        var usageByTarget: [String: [StorageUsage]] = [:]
        var seenContainers = Set<String>()
        var seenDevices = Set<String>()

        for mount in mounts {
            guard let kind = mapping[mount.deviceIdentifier] else { continue }

            switch kind {
            case let .apfs(container, targets, _, _):
                // All volumes of an APFS container share the same free space. Counting the
                // container more than once would multiply its usage.
                guard !container.isEmpty, seenContainers.insert(container).inserted else { continue }
                let usage = StorageUsage(totalBytes: mount.totalBytes, usedBytes: mount.usedBytes)
                for target in targets {
                    usageByTarget[target, default: []].append(usage)
                }

            case let .plain(target):
                guard seenDevices.insert(mount.deviceIdentifier).inserted else { continue }
                usageByTarget[target, default: []].append(
                    StorageUsage(totalBytes: mount.totalBytes, usedBytes: mount.usedBytes)
                )
            }
        }

        // Safety net: a container is mounted (per diskutil), but getfsstat did not report
        // its device. Fall back to the per-volume capacity from the plist.
        for kind in mapping.values {
            guard case let .apfs(container, targets, containerSize, isMounted) = kind,
                  isMounted,
                  seenContainers.insert(container).inserted,
                  let usage = apfsUsageFromPlist(
                    container: container,
                    entries: allDisksAndPartitions,
                    totalBytes: containerSize
                  )
            else { continue }

            for target in targets {
                usageByTarget[target, default: []].append(usage)
            }
        }

        var result: [String: StorageUsage] = [:]
        for (target, usages) in usageByTarget {
            if let combined = StorageUsage.combined(usages) {
                result[target] = combined
            }
        }
        return result
    }

    // MARK: - Mapping

    private enum VolumeKind {
        /// Volumes of an APFS container; `targets` are the whole disks carrying the container.
        case apfs(container: String, targets: [String], containerSize: Int64, isMounted: Bool)
        /// A plain (HFS+, exFAT, …) file system on a partition or whole disk.
        case plain(target: String)
    }

    private static func buildMapping(_ entries: [[String: Any]]) -> [String: VolumeKind] {
        var mapping: [String: VolumeKind] = [:]

        for entry in entries {
            let identifier = (entry["DeviceIdentifier"] as? String) ?? ""

            if let stores = entry["APFSPhysicalStores"] as? [[String: Any]],
               let volumes = entry["APFSVolumes"] as? [[String: Any]] {
                guard !identifier.isEmpty else { continue }

                let containerSize = int64(entry["Size"]) ?? 0
                let targets = Array(Set(stores.compactMap { store -> String? in
                    guard let device = store["DeviceIdentifier"] as? String else { return nil }
                    return wholeDiskIdentifier(for: device)
                })).sorted()
                let isMounted = volumes.contains { volume in
                    !((volume["MountPoint"] as? String) ?? "").isEmpty
                }
                let kind = VolumeKind.apfs(
                    container: identifier,
                    targets: targets,
                    containerSize: containerSize,
                    isMounted: isMounted
                )

                for volume in volumes {
                    guard let device = volume["DeviceIdentifier"] as? String, !device.isEmpty else { continue }
                    mapping[device] = kind
                }
                continue
            }

            guard !identifier.isEmpty else { continue }

            if let partitions = entry["Partitions"] as? [[String: Any]], !partitions.isEmpty {
                for partition in partitions {
                    guard let device = partition["DeviceIdentifier"] as? String, !device.isEmpty else { continue }
                    mapping[device] = .plain(target: identifier)
                }
            } else {
                mapping[identifier] = .plain(target: identifier)
            }
        }

        return mapping
    }

    /// `disk0s2` → `disk0`, `disk8` stays `disk8`.
    static func wholeDiskIdentifier(for device: String) -> String {
        guard device.hasPrefix("disk") else { return device }
        var index = device.index(device.startIndex, offsetBy: "disk".count)
        while index < device.endIndex, device[index].isNumber {
            index = device.index(after: index)
        }
        return String(device[..<index])
    }

    private static func apfsUsageFromPlist(
        container: String,
        entries: [[String: Any]],
        totalBytes: Int64
    ) -> StorageUsage? {
        guard totalBytes > 0 else { return nil }
        guard
            let entry = entries.first(where: { ($0["DeviceIdentifier"] as? String) == container }),
            let volumes = entry["APFSVolumes"] as? [[String: Any]]
        else {
            return nil
        }

        let devices = volumes.compactMap { $0["DeviceIdentifier"] as? String }
        var usedBytes: Int64 = 0
        var sawCapacity = false

        for volume in volumes {
            guard
                let device = volume["DeviceIdentifier"] as? String,
                let capacity = int64(volume["CapacityInUse"])
            else { continue }

            // Sealed snapshots appear as child devices and report the space of their volume.
            if devices.contains(where: { $0 != device && isDescendant(device, of: $0) }) {
                continue
            }

            usedBytes += capacity
            sawCapacity = true
        }

        guard sawCapacity else { return nil }
        return StorageUsage(totalBytes: totalBytes, usedBytes: usedBytes)
    }

    private static func isDescendant(_ device: String, of parent: String) -> Bool {
        guard device.hasPrefix(parent + "s") else { return false }
        let suffix = device.dropFirst(parent.count + 1)
        return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? NSNumber { return value.int64Value }
        if let value = value as? String { return Int64(value) }
        return nil
    }
}
