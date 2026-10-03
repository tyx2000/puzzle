import Darwin

/// Tree-sitter's allocator, with large blocks mapped straight from the system.
///
/// Compiling a highlight query allocates one transient block of several
/// megabytes. Freed through malloc, it stayed in the allocator's cache of large
/// blocks and counted against the app's footprint for good — 5 MB for nothing
/// once the query was built. A block mapped here is unmapped when tree-sitter
/// frees it, so it is gone the moment it is.
///
/// Everything smaller goes to malloc as before. A pointer that malloc handed
/// out is freed by malloc, so a block allocated before this was installed is
/// still freed correctly. Memory tree-sitter hands to the caller to free — a
/// node's description — goes back through `free(_:)` here, not `Darwin.free`.
enum TreeSitterAllocator {
    /// Blocks at least this large are mapped rather than malloc'd.
    static let mappedThreshold = 1 << 20

    /// Install once, before tree-sitter is used.
    static func install() {
        ts_set_allocator(tsMalloc, tsCalloc, tsRealloc, tsFree)
    }

    /// Free memory tree-sitter allocated and handed over.
    static func free(_ pointer: UnsafeMutableRawPointer?) { tsFree(pointer) }

    /// Live mapped blocks, and every block ever mapped, for the tests.
    static var mappedCountForTesting: Int {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return mapped.count
    }
    fileprivate(set) static var mappedEverForTesting = 0
    static func allocateForTesting(_ size: Int) -> UnsafeMutableRawPointer? { tsMalloc(size) }
    static func reallocateForTesting(_ pointer: UnsafeMutableRawPointer?,
                                     _ size: Int) -> UnsafeMutableRawPointer? {
        tsRealloc(pointer, size)
    }

    /// The mapped blocks still live, by address, with their mapped length.
    fileprivate static var mapped: [UInt: Int] = [:]
    /// On the heap, so the lock has one address for as long as it is used.
    fileprivate static let lock: os_unfair_lock_t = {
        let lock = os_unfair_lock_t.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        return lock
    }()
    fileprivate static let pageMask = UInt(getpagesize() - 1)

    fileprivate static func map(_ size: Int) -> UnsafeMutableRawPointer? {
        let length = (size + Int(pageMask)) & ~Int(pageMask)
        guard let block = mmap(nil, length, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0),
              block != MAP_FAILED else { return nil }
        os_unfair_lock_lock(lock)
        mapped[UInt(bitPattern: block)] = length
        mappedEverForTesting += 1
        os_unfair_lock_unlock(lock)
        return block
    }

    /// The mapped length of `pointer`, if it is one of the mapped blocks.
    /// Mapped blocks start on a page, so a pointer that does not is answered
    /// without taking the lock.
    fileprivate static func mappedLength(_ pointer: UnsafeMutableRawPointer, remove: Bool) -> Int? {
        let address = UInt(bitPattern: pointer)
        guard address & pageMask == 0 else { return nil }
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return remove ? mapped.removeValue(forKey: address) : mapped[address]
    }
}

private func tsMalloc(_ size: Int) -> UnsafeMutableRawPointer? {
    size >= TreeSitterAllocator.mappedThreshold ? TreeSitterAllocator.map(size) : malloc(size)
}

private func tsCalloc(_ count: Int, _ size: Int) -> UnsafeMutableRawPointer? {
    let (total, overflow) = count.multipliedReportingOverflow(by: size)
    guard !overflow else { return nil }
    // A fresh anonymous mapping is already zero-filled.
    return total >= TreeSitterAllocator.mappedThreshold
        ? TreeSitterAllocator.map(total) : calloc(count, size)
}

private func tsRealloc(_ pointer: UnsafeMutableRawPointer?, _ size: Int) -> UnsafeMutableRawPointer? {
    guard let pointer else { return tsMalloc(size) }
    if let length = TreeSitterAllocator.mappedLength(pointer, remove: false) {
        guard let moved = tsMalloc(size) else { return nil }
        memcpy(moved, pointer, min(length, size))
        tsFree(pointer)
        return moved
    }
    guard size >= TreeSitterAllocator.mappedThreshold else { return realloc(pointer, size) }
    guard let moved = TreeSitterAllocator.map(size) else { return nil }
    memcpy(moved, pointer, min(malloc_size(pointer), size))
    free(pointer)
    return moved
}

private func tsFree(_ pointer: UnsafeMutableRawPointer?) {
    guard let pointer else { return }
    if let length = TreeSitterAllocator.mappedLength(pointer, remove: true) {
        munmap(pointer, length)
    } else {
        free(pointer)
    }
}
