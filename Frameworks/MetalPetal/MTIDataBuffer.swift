//
//  MTIDataBuffer.swift
//  MetalPetal
//
//  Created by Yu Ao on 2019/1/24.
//

import Foundation
import Metal

#if SWIFT_PACKAGE
import MetalPetalObjectiveC.Core
#endif

extension MTIDataBuffer {
    
    public convenience init?<T>(values: [T], options: MTLResourceOptions = []) {
        let byteCount = MemoryLayout<T>.stride * values.count
        if byteCount == 0 {
            var dummy: UInt8 = 0
            self.init(bytes: &dummy, length: 0, options: options)
            return
        }
        let rawPointer = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: MemoryLayout<T>.alignment)
        defer {
            rawPointer.deallocate()
        }
        values.withUnsafeBytes { rawBuffer in
            rawPointer.copyMemory(from: rawBuffer.baseAddress!, byteCount: byteCount)
        }
        self.init(bytes: rawPointer, length: UInt(byteCount), options: options)
    }
    
    public func unsafeAccess<ReturnType, BufferContentType>(_ block: (UnsafeMutableBufferPointer<BufferContentType>) throws -> ReturnType) rethrows -> ReturnType {
        var buffer: UnsafeMutableBufferPointer<BufferContentType>!
        self.unsafeAccess { (pointer: UnsafeMutableRawPointer, length: UInt) -> Void in
            precondition(Int(length) % MemoryLayout<BufferContentType>.stride == 0)
            let count = Int(length) / MemoryLayout<BufferContentType>.stride
            buffer = UnsafeMutableBufferPointer(start: pointer.bindMemory(to: BufferContentType.self, capacity: count), count: count)
        }
        return try block(buffer)
    }
}
