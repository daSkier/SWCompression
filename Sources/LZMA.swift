//
//  LZMA.swift
//  SWCompression
//
//  Created by Timofey Solomko on 15.12.16.
//  Copyright © 2016 Timofey Solomko. All rights reserved.
//

import Foundation

/**
 Error happened during LZMA decompression.
 It may indicate that either the data is damaged or it might not be compressed with LZMA at all.

 - `WrongProperties`: unsupported LZMA properties (greater than 225).
 */
public enum LZMAError: Error {
    /// Properties byte was greater than 225.
    case WrongProperties
}

/// Provides function to decompress data, which were compressed with LZMA
public final class LZMA: DecompressionAlgorithm {

    final class OutWindow {

        private var byteBuffer: [UInt8]
        private var position: Int
        private var size: Int
        private var isFull: Bool

        private(set) var totalPosition: Int

        init(dictSize: Int) {
            self.byteBuffer = Array(repeating: 0, count: dictSize)
            self.position = 0
            self.totalPosition = 0
            self.size = dictSize
            self.isFull = false
        }

        /// Don't forget to put byte in `out` array.
        func put(byte: UInt8) {
            self.totalPosition += 1
            self.byteBuffer[position] = byte
            self.position += 1
            if self.position == self.size {
                self.position = 0
                self.isFull = true
            }
        }

        func byte(at distance: Int) -> UInt8 {
            return self.byteBuffer[distance <= self.position ? self.position - distance :
                self.size - distance + self.position]
        }

        func copyMatch(at distance: Int, length: Int) {
            for _ in 0..<length {
                self.put(byte: self.byte(at: distance))
            }
        }

        func check(distance: Int) -> Bool {
            return distance <= self.position || self.isFull
        }

        func isEmpty() -> Bool {
            return self.position == 0 && !self.isFull
        }

    }

    final class RangeDecoder {

        private static let topValue: Int = 1 << 24
        private static let numBitModelTotalBits: Int = 11
        private static let numMoveBits: Int = 5

        private var range: Int
        private var code: Int
        private(set) var isCorrupted: Bool

        init?(pointerData: DataWithPointer) {
            self.isCorrupted = false
            self.range = 0xFFFFFFFF
            self.code = 0

            let byte = pointerData.alignedByte()
            for _ in 0..<4 {
                self.code = (self.code << 8) | pointerData.alignedByte().toInt()
            }
            if byte != 0 || self.code == self.range {
                self.isCorrupted = true
                return nil
            }
        }

        func isFinishedOK() -> Bool {
            return self.code == 0
        }

        func normalize(pointerData: inout DataWithPointer) {
            if self.range < RangeDecoder.topValue {
                self.range <<= 8
                self.code = (self.code << 8) | pointerData.alignedByte().toInt()
            }
        }

        func decode(directBits: Int, pointerData: inout DataWithPointer) -> Int {
            var res = 0
            var count = directBits
            repeat {
                self.range >>= 1
                self.code -= self.range
                let t = 0 - (self.code >> 31)
                self.code += self.range & t

                if self.code == self.range {
                    self.isCorrupted = true
                }

                self.normalize(pointerData: &pointerData)

                res <<= 1
                res += t + 1
                count -= 1
            } while count > 0
            return res
        }

        func decode(bitWithProb prob: inout Int, pointerData: inout DataWithPointer) -> Int {
            let bound = (self.range >> RangeDecoder.numBitModelTotalBits) * prob
            let symbol: Int
            if self.code < bound {
                prob += ((1 << RangeDecoder.numBitModelTotalBits) - prob) >> RangeDecoder.numMoveBits
                self.range = bound
                symbol = 0
            } else {
                prob -= prob >> RangeDecoder.numMoveBits
                self.code -= bound
                self.range -= bound
                symbol = 1
            }
            self.normalize(pointerData: &pointerData)
            return symbol
        }

    }

    /**
     Decompresses `compressedData` with LZMA algortihm.

     If data passed is not actually compressed with LZMA, `LZMAError` will be thrown.

     - Parameter compressedData: Data compressed with LZMA.

     - Throws: `LZMAError` if unexpected byte (bit) sequence was encountered in `compressedData`.
     It may indicate that either the data is damaged or it might not be compressed with LZMA at all.

     - Returns: Decompressed data.
     */
    public static func decompress(compressedData data: Data) throws -> Data {
        /// Object with input data which supports convenient work with bit shifts.
        let pointerData = DataWithPointer(data: data, bitOrder: .reversed)
        return try decompress(pointerData: pointerData)
    }

    static func decompress(pointerData: DataWithPointer) throws -> Data {

        // First byte contains lzma properties.
        var properties = pointerData.alignedByte()
        if properties >= (9 * 5 * 5) {
            throw LZMAError.WrongProperties
        }
        /// The number of literal context bits
        let lc = properties % 9
        properties /= 9
        /// The number of pos bits
        let pb = properties / 5
        /// The number of literal pos bits
        let lp = properties % 5
        var dictionarySizeInProperties = 0
        for i in 0..<4 {
            dictionarySizeInProperties |= pointerData.alignedByte().toInt() << (8 * i)
        }
        let dictionarySize = dictionarySizeInProperties < (1 << 12) ? 1 << 12 : dictionarySizeInProperties

        print("lc: \(lc), lp: \(lp), pb: \(pb), dictionarySize: \(dictionarySize)")

        /// Size of uncompressed data. -1 means it is unknown.
        var uncompressedSize = 0
        for i in 0..<8 {
            uncompressedSize |= pointerData.alignedByte().toInt() << (8 * i)
        }
        uncompressedSize = Double(uncompressedSize) == pow(Double(2), Double(64)) - 1 ? -1 : uncompressedSize

        /// Object for storing output data
        var out: [UInt8] = uncompressedSize == -1 ? [] : Array(repeating: 0, count: uncompressedSize)

        print("uncompressedSize: \(uncompressedSize)")

        let outWindow = OutWindow(dictSize: dictionarySize)
        let literalProbs = Array(repeating: 0, count: 0x300 << (lc + lp).toInt())

        return Data(bytes: out)
    }
    
}