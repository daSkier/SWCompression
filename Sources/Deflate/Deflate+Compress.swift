// Copyright (c) 2017 Timofey Solomko
// Licensed under MIT License
//
// See LICENSE for license information

import Foundation

extension Deflate: CompressionAlgorithm {

    /**
     Compresses `data` with Deflate algortihm.

     - Parameter data: Data to compress.

     - Note: Currently, SWCompression creates only one block for all data
     and the block can either be uncompressed or compressed with static Huffman encoding.
     Choice of one block type or the other depends on bytes' statistics of data.
     However, if data size is greater than 65535 (the maximum value stored in 2 bytes),
     then static Huffman block will be created.
     */
    public static func compress(data: Data) -> Data {
        let bytes = data.toArray(type: UInt8.self)

        let bldCodes = Deflate.lengthEncode(bytes)

        // Let's count possible sizes according to statistics.

        // Uncompressed block size calculation is simple:
        let uncompBlockSize = 1 + 2 + 2 + bytes.count // Header, length, n-length and data.

        // Static Huffman size is more complicated...
        var bitsCount = 3 // Three bits for block's header.
        for (symbol, symbolCount) in bldCodes.stats.enumerated() {
            let codeSize: Int
            // There are extra bits for some codes.
            let extraBitsCount: Int
            switch symbol {
            case 0...143:
                codeSize = 8
                extraBitsCount = 0
            case 144...255:
                codeSize = 9
                extraBitsCount = 0
            case 256...279:
                codeSize = 7
                extraBitsCount = 256 <= symbol && symbol <= 260 ? 0 : (((symbol - 257) >> 2) - 1)
            case 280...285:
                codeSize = 8
                extraBitsCount = symbol == 285 ? 0 : (((symbol - 257) >> 2) - 1)
            case 286...315:
                codeSize = 5
                extraBitsCount = symbol == 286 || symbol == 287 ? 0 : (((symbol - 286) >> 1) - 1)
            default:
                fatalError("Symbol is not found.")
            }
            bitsCount += (symbolCount * (codeSize + extraBitsCount))
        }
        let staticHuffmanBlockSize = bitsCount % 8 == 0 ? bitsCount / 8 : bitsCount / 8 + 1

        // Since `length` of uncompressed block is 16-bit integer,
        // there is a limitation on size of uncompressed block.
        // Falling back to static Huffman encoding in case of big uncompressed block is a band-aid solution.
        if uncompBlockSize <= staticHuffmanBlockSize && uncompBlockSize <= 65535 {
            // If according to our calculations static huffman will not make output smaller than input,
            // we fallback to creating uncompressed block.
            // In this case dynamic Huffman encoding can be efficient.
            // TODO: Implement dynamic Huffman code!
            return Data(bytes: Deflate.createUncompressedBlock(bytes))
        } else {
            return Data(bytes: Deflate.encodeHuffmanBlock(bldCodes.codes))
        }
    }

    private static func createUncompressedBlock(_ bytes: [UInt8]) -> [UInt8] {
        let bitWriter = BitWriter(bitOrder: .reversed)

        // Write block header.
        // Note: Only one block is supported for now.
        bitWriter.write(bit: 1)
        bitWriter.write(bits: [0, 0])

        // Before writing lengths we need to discard remaining bits in current byte.
        bitWriter.finish()

        // Write data's length.
        bitWriter.write(number: bytes.count, bitsCount: 16)
        // Write data's n-length.
        bitWriter.write(number: bytes.count ^ (1 << 16 - 1), bitsCount: 16)

        var out = bitWriter.buffer

        // Write actual data.
        for byte in bytes {
            out.append(byte)
        }

        return out
    }

    private static func encodeHuffmanBlock(_ bldCodes: [BLDCode]) -> [UInt8] {
        let bitWriter = BitWriter(bitOrder: .reversed)

        // Write block header.
        // Note: For now it is only static huffman blocks.
        // Note: Only one block is supported for now.
        bitWriter.write(bit: 1)
        bitWriter.write(bits: [1, 0])

        // Constructing Huffman trees for the case of block with preset alphabets.
        // In this case codes for literals and distances are fixed.
        /// Huffman tree for literal and length symbols/codes.
        let mainLiterals = EncodingHuffmanTree(lengths: Constants.staticHuffmanBootstrap,
                                               bitWriter)
        /// Huffman tree for backward distance symbols/codes.
        let mainDistances = EncodingHuffmanTree(lengths: Constants.staticHuffmanDistancesBootstrap,
                                                bitWriter)

        for code in bldCodes {
            switch code {
            case let .byte(byte):
                mainLiterals.code(symbol: byte.toInt())
            case let .lengthDistance(length, distance):
                let lengthSymbol = Constants.lengthCode[Int(length) - 3]
                let lengthExtraBits = Int(length) - Constants.lengthBase[lengthSymbol - 257]
                let lengthExtraBitsCount = (257 <= lengthSymbol && lengthSymbol <= 260) || lengthSymbol == 285 ?
                    0 : (((lengthSymbol - 257) >> 2) - 1)
                mainLiterals.code(symbol: lengthSymbol)
                bitWriter.write(number: lengthExtraBits, bitsCount: lengthExtraBitsCount)

                let distanceSymbol = ((Constants.distanceBase.index { $0 > Int(distance) }) ?? 30) - 1
                let distanceExtraBits = Int(distance) - Constants.distanceBase[distanceSymbol]
                let distanceExtraBitsCount = distanceSymbol == 0 || distanceSymbol == 1 ?
                    0 : ((distanceSymbol >> 1) - 1)
                mainDistances.code(symbol: distanceSymbol)
                bitWriter.write(number: distanceExtraBits, bitsCount: distanceExtraBitsCount)
            }
        }

        // End data symbol.
        mainLiterals.code(symbol: 256)
        bitWriter.finish()

        return bitWriter.buffer
    }

    private enum BLDCode {
        case byte(UInt8)
        case lengthDistance(UInt16, UInt16)
    }

    private static func lengthEncode(_ rawBytes: [UInt8]) -> (codes: [BLDCode], stats: [Int]) {
        var buffer: [BLDCode] = []
        var inputIndex = 0
        /// Keys --- three-byte crc32, values --- positions in `rawBytes`.
        var dictionary = [UInt32: Int]()

        var stats = Array(repeating: 0, count: 316)

        // Last two bytes of input will be considered separately.
        // This also allows to use length encoding for arrays with size less than 3.
        while inputIndex < rawBytes.count - 2 {
            let byte = rawBytes[inputIndex]

            let threeByteCrc = CheckSums.crc32([rawBytes[inputIndex],
                                                rawBytes[inputIndex + 1],
                                                rawBytes[inputIndex + 2]])

            if let matchStartIndex = dictionary[threeByteCrc] {
                // We need to update position of this match to keep distances as small as possible.
                dictionary[threeByteCrc] = inputIndex

                /// - Note: Minimum match length equals to three.
                var matchLength = 3
                /// Cyclic index which is used to compare bytes in match and in input.
                var repeatIndex = matchStartIndex + matchLength

                /// - Note: Maximum allowed distance equals to 32768.
                let distance = inputIndex - matchStartIndex

                // Again, the distance cannot be greater than 32768.
                if distance <= 32768 {
                    while inputIndex + matchLength < rawBytes.count &&
                        rawBytes[inputIndex + matchLength] == rawBytes[repeatIndex] && matchLength < 258 {
                            matchLength += 1
                            repeatIndex += 1
                            if repeatIndex > inputIndex {
                                repeatIndex = matchStartIndex + 1
                            }
                    }
                    buffer.append(BLDCode.lengthDistance(UInt16(truncatingIfNeeded: matchLength),
                                                         UInt16(truncatingIfNeeded: distance)))
                    stats[Constants.lengthCode[matchLength - 3]] += 1 // Length symbol.
                    stats[286 + ((Constants.distanceBase.index { $0 > distance }) ?? 30) - 1] += 1 // Distance symbol.
                    inputIndex += matchLength
                } else {
                    buffer.append(BLDCode.byte(byte))
                    stats[byte.toInt()] += 1
                    inputIndex += 1
                }
            } else {
                // We need to remember where we met this three-byte sequence.
                dictionary[threeByteCrc] = inputIndex

                buffer.append(BLDCode.byte(byte))
                stats[byte.toInt()] += 1
                inputIndex += 1
            }
            // TODO: Add limitation for dictionary size.
        }

        // For last two bytes there certainly will be no match.
        // Moreover, `threeByteCrc` cannot be computed, so we need to put them in as `.byte`s.
        while inputIndex < rawBytes.count {
            let byte = rawBytes[inputIndex]
            buffer.append(BLDCode.byte(byte))
            stats[byte.toInt()] += 1
            inputIndex += 1
        }

        // End of block symbol (256) should also be counted.
        stats[256] += 1

        return (buffer, stats)
    }

}