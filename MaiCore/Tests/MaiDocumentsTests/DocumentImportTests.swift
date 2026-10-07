import Foundation
import MaiCore
import Testing

@testable import MaiDocuments

private let fixturesDirectory = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .appendingPathComponent("Fixtures")

// Raw deflate streams produced by zlib: a stored block, a fixed-Huffman block,
// and a dynamic-Huffman block over 400 pseudo-random words.
private let storedSample: [UInt8] = [
  0x01, 0x14, 0x00, 0xeb, 0xff, 0x73, 0x74, 0x6f, 0x72, 0x65, 0x64, 0x20,
  0x62, 0x6c, 0x6f, 0x63, 0x6b, 0x20, 0x70, 0x61, 0x79, 0x6c, 0x6f, 0x61,
  0x64,
]
private let fixedSample: [UInt8] = [
  0x4b, 0xcb, 0xac, 0x48, 0x4d, 0x51, 0xc8, 0x28, 0x4d, 0x4b, 0xcb, 0x4d,
  0xcc, 0x53, 0x48, 0xc3, 0xcd, 0x03, 0x00,
]
private let dynamicSample: [UInt8] = [
  0x4d, 0x57, 0x6d, 0x6e, 0xdb, 0x4a, 0x0c, 0xbc, 0x8a, 0x8e, 0x20, 0x72,
  0xc9, 0x5d, 0xf2, 0x38, 0x6e, 0x1b, 0x34, 0xc6, 0x8b, 0x9b, 0xa0, 0x1f,
  0x40, 0xf1, 0x4e, 0xdf, 0xe1, 0xc7, 0xca, 0xf9, 0xe3, 0xc8, 0xb2, 0xc4,
  0x1d, 0x0e, 0x87, 0x43, 0xe6, 0xed, 0xf6, 0xf8, 0xf2, 0xed, 0xe6, 0xeb,
  0x3c, 0x5e, 0x3e, 0x7e, 0xdd, 0xdf, 0xde, 0x7f, 0xc8, 0x29, 0xc7, 0xc7,
  0xeb, 0x5d, 0xfc, 0xf8, 0x7e, 0x7b, 0x3c, 0x6e, 0x26, 0xe7, 0xf1, 0xeb,
  0xfe, 0xfd, 0x71, 0xf3, 0x79, 0x3c, 0xfe, 0x28, 0x3e, 0xbf, 0xbc, 0xfc,
  0xbe, 0xf9, 0xa0, 0xe3, 0xe7, 0xeb, 0x3b, 0x93, 0xe7, 0x57, 0xb3, 0xe3,
  0xef, 0x5d, 0xd8, 0xea, 0x15, 0x96, 0x59, 0x17, 0x3a, 0x05, 0xf7, 0xe7,
  0x79, 0xfc, 0xbe, 0xfd, 0x21, 0x9e, 0xc7, 0xef, 0x57, 0x3c, 0x3b, 0x45,
  0x23, 0xfe, 0x8e, 0xa4, 0x9e, 0x3f, 0xcb, 0xd9, 0x81, 0xdd, 0xeb, 0x31,
  0x59, 0x75, 0xac, 0x2d, 0xdf, 0xc8, 0x18, 0xaf, 0xfc, 0xbd, 0xd3, 0xfe,
  0x85, 0x38, 0xdf, 0x1c, 0xa4, 0xfd, 0xe4, 0xd0, 0xe3, 0xeb, 0xeb, 0x9d,
  0x4c, 0x8f, 0x6f, 0x2f, 0x6f, 0x11, 0x59, 0xe3, 0xf7, 0xa9, 0x72, 0x20,
  0xde, 0x30, 0xea, 0xdb, 0xc0, 0x83, 0x78, 0x80, 0x16, 0x3f, 0xd2, 0xf1,
  0xa7, 0x83, 0x13, 0x6e, 0xdf, 0x27, 0x8e, 0xc8, 0x60, 0x32, 0xd6, 0xf1,
  0x96, 0xd4, 0xc8, 0x9a, 0xf1, 0xa4, 0x03, 0xf6, 0xfb, 0xe3, 0xfe, 0xf5,
  0xe7, 0xfb, 0x8f, 0x01, 0xb2, 0xfe, 0xbb, 0x7d, 0x7c, 0xdc, 0x18, 0xa1,
  0xff, 0x47, 0xec, 0x05, 0x08, 0x09, 0xda, 0x46, 0x22, 0x3a, 0x57, 0x90,
  0xa3, 0x48, 0xa9, 0x42, 0x2c, 0x10, 0xd2, 0xef, 0xb2, 0xcb, 0x3e, 0x71,
  0x49, 0x03, 0xe2, 0x60, 0x89, 0xa6, 0xf5, 0xd3, 0xa4, 0x20, 0xe8, 0x2e,
  0x60, 0x38, 0x09, 0xb1, 0xcc, 0x0a, 0x2c, 0x24, 0x2e, 0xb5, 0x1d, 0x74,
  0x88, 0x45, 0x1e, 0x43, 0x6d, 0x07, 0xd4, 0xd3, 0xe2, 0x78, 0xa3, 0xeb,
  0x34, 0x00, 0xcd, 0x42, 0xf8, 0x5c, 0xc7, 0xfd, 0x1d, 0xa4, 0x22, 0x58,
  0xe4, 0x6e, 0x7d, 0x7f, 0x32, 0x9e, 0x7c, 0xf9, 0x8e, 0x04, 0xac, 0x32,
  0x9a, 0xb8, 0x13, 0xb4, 0xf8, 0x7a, 0x02, 0xa6, 0x3c, 0xc6, 0x13, 0xc6,
  0x00, 0xb6, 0xdb, 0xdb, 0xc7, 0x2b, 0x22, 0x8e, 0x8b, 0x0e, 0x5c, 0x06,
  0x0b, 0x93, 0x37, 0xf1, 0xa7, 0x26, 0x74, 0xe6, 0x51, 0x51, 0x69, 0xf4,
  0x39, 0xac, 0xe3, 0xf8, 0x81, 0x5a, 0x07, 0xd5, 0xc6, 0xf9, 0x96, 0xa8,
  0xe3, 0x96, 0xe2, 0xdc, 0x00, 0xe8, 0x10, 0x5f, 0x57, 0xdb, 0x46, 0x88,
  0xca, 0x4c, 0x2a, 0x71, 0x2e, 0xe8, 0x82, 0x43, 0x1e, 0xc0, 0x17, 0x2f,
  0x39, 0xd2, 0x48, 0xda, 0x09, 0x75, 0xc8, 0x7c, 0xc8, 0x2e, 0x19, 0x33,
  0x0a, 0x08, 0xc0, 0x8c, 0x28, 0x09, 0x58, 0x3c, 0xcb, 0x48, 0xe0, 0x2f,
  0x0e, 0x62, 0xeb, 0xfb, 0x04, 0xa1, 0xff, 0xbd, 0x2b, 0x44, 0x85, 0xb0,
  0x9c, 0xa2, 0x18, 0x90, 0x6a, 0x47, 0x59, 0x55, 0x4a, 0x5f, 0x63, 0x93,
  0x3c, 0xc1, 0x69, 0xd4, 0x43, 0x57, 0xe6, 0x28, 0x33, 0x8f, 0x31, 0x6a,
  0x51, 0xca, 0x49, 0x99, 0xa1, 0xe1, 0x93, 0x20, 0x00, 0x48, 0x4a, 0x02,
  0x2b, 0x38, 0x0a, 0x8a, 0xec, 0xc8, 0x94, 0x29, 0x53, 0x27, 0xe2, 0xae,
  0xe5, 0xa4, 0x62, 0x8c, 0x90, 0x7e, 0xa2, 0xd2, 0x67, 0x22, 0x8a, 0xf7,
  0x93, 0x56, 0x5f, 0x94, 0x18, 0x1b, 0xf8, 0xe2, 0x8c, 0xc8, 0x79, 0x92,
  0x72, 0xf4, 0x14, 0x43, 0x0b, 0x78, 0x82, 0xa2, 0x53, 0x65, 0xb7, 0x01,
  0xa1, 0xb6, 0x90, 0xd3, 0x5a, 0xf1, 0x89, 0x2a, 0x66, 0x45, 0x6c, 0xed,
  0xf0, 0x71, 0x64, 0xd6, 0x66, 0xe8, 0xd9, 0x45, 0xc2, 0x39, 0x28, 0x4f,
  0xc9, 0x8b, 0xa6, 0x66, 0xa3, 0x27, 0xfc, 0xa0, 0x01, 0x5f, 0xc6, 0xd3,
  0x2c, 0xd6, 0xd9, 0xfd, 0xe2, 0x63, 0x36, 0x2c, 0xb4, 0x4b, 0x3c, 0x73,
  0x66, 0x97, 0x47, 0xf9, 0xb2, 0x32, 0x8b, 0xaa, 0xc0, 0x3a, 0x4e, 0x80,
  0x73, 0x7c, 0x06, 0x03, 0x23, 0xba, 0x30, 0x2a, 0xa8, 0xd2, 0x4d, 0xbc,
  0x3c, 0x09, 0x1f, 0xa8, 0x5e, 0x24, 0xc4, 0x97, 0xb8, 0x0d, 0xaf, 0x44,
  0x87, 0xf1, 0xd5, 0x6a, 0x0b, 0x89, 0x47, 0x19, 0xf2, 0x2b, 0x23, 0x8d,
  0xec, 0x39, 0x41, 0xf8, 0x25, 0xcd, 0x11, 0x5e, 0x2f, 0xd9, 0x8f, 0xfc,
  0x4b, 0x9e, 0x39, 0x4d, 0xb8, 0x16, 0x08, 0xd2, 0xb5, 0x13, 0x8f, 0xda,
  0x43, 0x8e, 0xa5, 0xa5, 0xb3, 0x21, 0x09, 0x0c, 0x23, 0x20, 0x02, 0x59,
  0x7c, 0x7b, 0xf6, 0xad, 0xf3, 0x65, 0x1a, 0x06, 0x2f, 0x69, 0x75, 0x9d,
  0x81, 0x77, 0x54, 0x1d, 0xa0, 0xb1, 0x30, 0x22, 0x66, 0x20, 0xb4, 0x33,
  0xfb, 0x67, 0x75, 0xe9, 0xcd, 0x4b, 0xf5, 0x92, 0x26, 0x3b, 0xa4, 0x1b,
  0xd1, 0xb8, 0xc9, 0x97, 0xf3, 0xb2, 0x19, 0x21, 0xaa, 0x7b, 0x3e, 0xdb,
  0x8b, 0x97, 0x54, 0xcf, 0xd0, 0xba, 0xba, 0x04, 0x19, 0xf6, 0xd5, 0xcc,
  0x42, 0xe6, 0x9b, 0x41, 0x12, 0xa2, 0x87, 0xb4, 0x37, 0x50, 0x38, 0x50,
  0x5f, 0x4a, 0x19, 0x8a, 0x6b, 0x90, 0x40, 0xba, 0x7d, 0x05, 0x4e, 0xb8,
  0x43, 0x52, 0xe5, 0x64, 0x10, 0x4e, 0x9e, 0x3f, 0xe7, 0x6e, 0xec, 0xe1,
  0x8d, 0x48, 0xaf, 0x0e, 0x89, 0x4c, 0xa2, 0x1c, 0x45, 0x53, 0x13, 0xce,
  0x68, 0x87, 0xd4, 0x99, 0xd2, 0x28, 0x36, 0x97, 0xa5, 0xb1, 0x8c, 0x51,
  0x95, 0x50, 0x70, 0x8e, 0xe6, 0xd6, 0x2b, 0x8f, 0xed, 0x44, 0x23, 0x2f,
  0x32, 0x8b, 0xb9, 0xca, 0xce, 0x46, 0x56, 0x56, 0x50, 0x7f, 0xfc, 0x21,
  0x04, 0x28, 0xf7, 0xd7, 0x14, 0xa6, 0x82, 0xe4, 0x42, 0xeb, 0x97, 0x21,
  0x2d, 0xa8, 0xbc, 0x0c, 0x69, 0xb4, 0x26, 0xfd, 0x3a, 0x87, 0xd6, 0x13,
  0xb9, 0x7d, 0xb2, 0x62, 0xde, 0xc3, 0xa1, 0x06, 0x5a, 0xe0, 0x04, 0x49,
  0x5a, 0x87, 0xea, 0x8c, 0x16, 0xb2, 0x73, 0x74, 0x23, 0x9e, 0xb2, 0xcd,
  0xb8, 0x35, 0x83, 0x03, 0x53, 0x67, 0xfd, 0x80, 0x92, 0x6f, 0x2c, 0xba,
  0x74, 0xf7, 0x45, 0x4f, 0x47, 0x81, 0x07, 0x76, 0xd7, 0x73, 0x6a, 0x7d,
  0x72, 0x1e, 0x12, 0x0a, 0x06, 0x1a, 0xb6, 0x2b, 0x0f, 0xe5, 0x1e, 0xbd,
  0xc6, 0x61, 0x24, 0x11, 0xb5, 0xb8, 0xa4, 0x4c, 0xdd, 0xbc, 0x4c, 0xdd,
  0xa5, 0xe1, 0x38, 0x55, 0x29, 0xe6, 0xb9, 0x23, 0x10, 0xf4, 0x85, 0xd1,
  0x02, 0x5b, 0x83, 0x27, 0x29, 0x5f, 0xe3, 0x28, 0x9d, 0x51, 0x62, 0x9a,
  0x2e, 0x29, 0x5f, 0xda, 0xbe, 0x70, 0x36, 0x11, 0x4e, 0x97, 0xb0, 0x1c,
  0x25, 0x89, 0xae, 0x41, 0xb6, 0x31, 0x01, 0x3e, 0x69, 0x4f, 0xaf, 0xd1,
  0xec, 0x7e, 0x9d, 0xc9, 0xdc, 0x86, 0xe2, 0xab, 0x65, 0x23, 0x67, 0x78,
  0x0f, 0xcd, 0xec, 0x0a, 0xd3, 0xdd, 0x68, 0xb3, 0x0c, 0x5d, 0x72, 0x93,
  0x10, 0xda, 0xac, 0xc4, 0xe0, 0x4b, 0x6b, 0xd0, 0xbe, 0xe1, 0xdb, 0xa0,
  0x56, 0x9b, 0xe3, 0x90, 0x3d, 0xa4, 0xe7, 0xc5, 0xf3, 0xe2, 0xee, 0xc4,
  0xe1, 0x3b, 0x90, 0xf2, 0x25, 0xff, 0x81, 0xb4, 0xc2, 0xc6, 0xc1, 0x6d,
  0xcd, 0x89, 0x3d, 0xb0, 0xdd, 0x1b, 0xe3, 0x1e, 0x0b, 0xa8, 0x52, 0x4e,
  0x5d, 0x94, 0x26, 0x24, 0xc4, 0x4f, 0xb9, 0xd8, 0x88, 0x41, 0x61, 0x38,
  0x32, 0xb2, 0x18, 0xed, 0x2c, 0x08, 0xf4, 0xc9, 0xa7, 0x43, 0x2b, 0x50,
  0xd5, 0xc7, 0x7d, 0xd1, 0x5e, 0x1f, 0x30, 0x3e, 0x53, 0xf0, 0xe5, 0xa6,
  0x16, 0xb2, 0x77, 0xea, 0xfd, 0x88, 0xb7, 0x38, 0xe6, 0xb5, 0x6d, 0x21,
  0x8d, 0x78, 0x1c, 0xf5, 0xd8, 0x9d, 0xbb, 0xf6, 0xde, 0x54, 0x27, 0x9a,
  0xb5, 0xc8, 0x64, 0x5e, 0x74, 0xec, 0xd9, 0xc3, 0x25, 0x88, 0x39, 0x3e,
  0x75, 0x67, 0x60, 0x5a, 0x7b, 0xf7, 0x72, 0x48, 0xa3, 0xca, 0xeb, 0xe5,
  0x24, 0x3c, 0x2b, 0xdf, 0x58, 0x9a, 0xe2, 0x77, 0x34, 0x64, 0xed, 0x01,
  0xd2, 0xa3, 0x5b, 0x25, 0x9d, 0x3f, 0x56, 0xaf, 0xad, 0x4a, 0x38, 0x79,
  0xae, 0x59, 0x65, 0xe8, 0xd7, 0x46, 0xc0, 0x5a, 0x1b, 0x1c, 0x6d, 0xc1,
  0x6b, 0xf7, 0x4e, 0x2a, 0x4c, 0x53, 0xc2, 0xac, 0x74, 0x49, 0xf3, 0xb4,
  0x4d, 0x64, 0x6c, 0x9b, 0x92, 0x41, 0x75, 0x8f, 0x93, 0x70, 0x06, 0x0c,
  0x78, 0xaf, 0x79, 0x43, 0xa9, 0x14, 0xe6, 0x1e, 0xf7, 0x31, 0xa9, 0x42,
  0xe7, 0x9a, 0xba, 0x8c, 0xe5, 0x2a, 0xcd, 0x2e, 0x56, 0x8b, 0x40, 0x93,
  0x0b, 0xa9, 0x3e, 0x07, 0x5c, 0x4f, 0xa0, 0x29, 0x6d, 0xb1, 0x7e, 0x16,
  0xc7, 0xa1, 0xbc, 0xe0, 0x40, 0xbb, 0x1a, 0xd3, 0x62, 0x74, 0x9b, 0xa7,
  0x1e, 0x27, 0x04, 0x51, 0x4c, 0x5c, 0x0e, 0x76, 0x7a, 0xdd, 0x79, 0x2e,
  0x73, 0xd4, 0x6e, 0x1e, 0x75, 0xdc, 0xcb, 0x50, 0x91, 0xb2, 0x76, 0xaf,
  0x85, 0xc0, 0x32, 0xa3, 0x01, 0x59, 0x37, 0xfa, 0x5e, 0x1e, 0xe1, 0x4e,
  0x30, 0x60, 0x28, 0xa2, 0xab, 0x18, 0xf8, 0x63, 0xc9, 0xb9, 0xc7, 0xaa,
  0x13, 0x10, 0x56, 0x36, 0x42, 0x2c, 0x99, 0x51, 0x43, 0xef, 0x72, 0x7b,
  0x1d, 0x61, 0xa3, 0x61, 0xc7, 0x3e, 0x8c, 0xfd, 0x02, 0x49, 0xe5, 0x3e,
  0x72, 0xb6, 0xe7, 0x8d, 0x73, 0x27, 0x20, 0x3d, 0xd0, 0xac, 0xf6, 0x58,
  0xcb, 0xb2, 0x18, 0x46, 0xf9, 0xb6, 0x5e, 0x5c, 0xe2, 0x2a, 0x5a, 0x7f,
  0xb7, 0x8b, 0xef, 0x5d, 0x74, 0x8d, 0x6c, 0x5d, 0x6d, 0x35, 0x2c, 0xb9,
  0x46, 0x5f, 0xd8, 0xc1, 0x53, 0x64, 0xb8, 0x70, 0xca, 0x62, 0x4d, 0x54,
  0x12, 0xb6, 0xa2, 0x39, 0xf5, 0xac, 0xfe, 0x4d, 0x20, 0xc9, 0xf6, 0x5b,
  0xab, 0x14, 0x61, 0xdb, 0xb2, 0x25, 0x1d, 0x41, 0x7b, 0x2a, 0x63, 0xa7,
  0x6b, 0x9b, 0x29, 0xb8, 0x4d, 0x0c, 0xde, 0xdd, 0x40, 0x51, 0x70, 0xec,
  0x0e, 0xc6, 0xff, 0x00,
]
private let dynamicText =
  "lambda970 epsilon404 phi49 gamma840 sigma96 mu596 beta931 rho219 beta88 xi428 gamma246 gamma564 xi60 tau126 theta645 phi596 beta590 tau406 beta999 theta47 sigma879 epsilon296 xi147 sigma120 tau315 sigma835 chi185 delta595 tau654 eta381 delta560 psi64 tau61 upsilon210 pi696 sigma437 lambda476 tau945 omicron370 kappa254 zeta715 theta83 tau307 rho506 lambda746 omicron294 upsilon74 delta524 xi168 lambda155 pi431 beta985 chi79 sigma586 lambda348 psi358 upsilon508 tau816 omicron70 gamma967 iota485 psi680 gamma62 omega718 kappa662 tau697 omicron291 psi395 chi355 alpha963 omicron363 zeta625 delta505 beta223 kappa132 omega253 nu400 pi82 zeta459 nu562 iota904 epsilon838 xi884 sigma285 psi425 mu699 nu980 theta154 gamma180 epsilon237 chi238 alpha496 tau186 iota288 alpha149 xi547 mu624 tau326 epsilon707 rho973 upsilon670 chi757 beta467 chi817 sigma401 nu408 nu106 pi649 nu63 eta68 eta451 zeta112 lambda615 beta104 alpha580 epsilon549 delta971 mu628 alpha72 eta628 nu152 phi258 mu616 mu485 delta118 pi477 pi495 kappa87 epsilon104 omega350 omega271 pi848 psi165 rho23 eta973 rho370 epsilon706 sigma936 alpha776 rho305 phi884 gamma712 iota530 mu930 zeta364 theta545 sigma797 rho337 phi228 upsilon830 eta825 theta837 nu757 theta204 rho504 mu748 alpha28 iota483 iota198 psi619 mu457 omega357 mu82 theta104 theta481 eta345 eta494 upsilon921 upsilon860 alpha490 phi352 phi86 chi122 nu801 psi768 eta489 zeta444 phi340 gamma820 omega405 omicron411 omega969 gamma742 zeta174 epsilon28 epsilon604 omicron825 phi149 upsilon846 upsilon485 chi959 mu159 sigma561 epsilon21 alpha818 omega665 delta539 omega956 epsilon444 eta845 eta28 iota217 kappa513 theta782 tau333 iota557 xi854 epsilon62 omega362 omicron678 tau834 rho430 rho133 sigma155 rho522 alpha893 omicron795 zeta623 alpha794 epsilon176 epsilon484 upsilon742 delta569 beta333 chi530 rho568 pi803 delta904 sigma58 theta195 iota43 delta519 omicron575 alpha778 gamma453 lambda627 rho620 rho204 psi283 omicron520 sigma826 pi519 theta715 rho897 iota944 sigma914 eta860 omicron140 xi124 nu452 lambda74 chi246 xi74 eta685 kappa802 delta918 epsilon962 psi658 chi374 epsilon259 epsilon990 omicron224 omega975 delta407 pi166 chi852 theta165 psi441 rho413 lambda431 eta365 lambda94 omega374 alpha346 sigma469 omicron720 alpha393 lambda529 upsilon302 rho983 gamma115 theta995 delta86 iota278 beta927 zeta276 epsilon839 xi869 chi838 iota415 epsilon549 rho584 pi717 lambda91 iota58 psi187 xi916 gamma275 alpha649 gamma820 iota85 upsilon876 theta68 iota883 delta464 alpha347 sigma427 iota636 epsilon44 rho726 theta960 delta992 zeta268 beta185 eta954 kappa643 kappa543 eta296 omicron512 chi182 iota355 alpha256 beta15 alpha750 rho564 eta526 pi251 omicron108 chi838 phi442 chi506 sigma854 nu993 rho315 psi220 theta350 eta852 psi746 phi143 nu355 beta857 epsilon14 gamma640 omega900 iota441 zeta56 gamma681 nu891 rho686 kappa613 theta709 kappa46 omicron189 zeta275 omicron3 iota372 lambda995 sigma331 theta35 kappa223 mu187 alpha343 nu85 pi285 rho671 eta254 rho794 alpha93 iota836 gamma147 nu600 beta403 alpha306 kappa644 theta86 tau980 rho873 epsilon673 psi802 upsilon398 lambda737 pi153 kappa741 upsilon658 epsilon44 psi913 rho642 xi751 psi831 rho142 rho770 rho582 alpha846 chi598 psi699 psi658 theta87 alpha42 epsilon652 mu982"

@Test("The pure Swift inflater decodes stored, fixed, and dynamic deflate blocks")
func inflateDecodesEveryBlockType() throws {
  #expect(try Inflate.decompress(Data(storedSample)) == Data("stored block payload".utf8))
  #expect(
    try Inflate.decompress(Data(fixedSample))
      == Data("fixed huffman fixed huffman fixed huffman".utf8))
  let dynamic = try Inflate.decompress(Data(dynamicSample), expectedSize: dynamicText.utf8.count)
  #expect(String(decoding: dynamic, as: UTF8.self) == dynamicText)
  #expect(throws: Inflate.Failure.truncatedInput) {
    try Inflate.decompress(Data(fixedSample.dropLast(4)))
  }
  #expect(throws: Inflate.Failure.invalidBlockType) {
    try Inflate.decompress(Data([0x07]))
  }
}

@Test("The zip reader lists stored and deflated entries and skips directories")
func zipReaderReadsFixture() throws {
  let entries = try ZipArchiveReader.entries(
    at: fixturesDirectory.appendingPathComponent("sample.docx"))
  #expect(
    Set(entries.map(\.path)) == [
      "[Content_Types].xml", "word/document.xml", "word/numbering.xml",
      "word/_rels/document.xml.rels",
    ])
  let document = try #require(entries.first { $0.path == "word/document.xml" })
  #expect(String(decoding: document.data, as: UTF8.self).contains("Fixture Report"))
  #expect(throws: ZipArchiveError.notAnArchive) {
    try ZipArchiveReader.entries(in: Data("not a zip archive at all".utf8))
  }
}

@Test("The zip writer produces archives the reader accepts")
func zipWriterRoundTrips() throws {
  let archive = ZipArchiveWriter.archive(entries: [
    (path: "a.txt", data: Data("hello".utf8)),
    (path: "dir/b.bin", data: Data([0, 1, 2, 255])),
  ])
  let entries = try ZipArchiveReader.entries(in: archive)
  #expect(entries.map(\.path) == ["a.txt", "dir/b.bin"])
  #expect(entries[0].data == Data("hello".utf8))
  #expect(entries[1].data == Data([0, 1, 2, 255]))
  #expect(ZipArchiveWriter.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
}

@Test("A real Word document converts to Markdown")
func docxFixtureConvertsToMarkdown() throws {
  let markdown = try DOCXImporter.markdown(
    from: fixturesDirectory.appendingPathComponent("sample.docx"))
  #expect(
    markdown == """
      # Fixture Report

      Plain text with **bold** words and a [link](https://example.com/report).

      1. First item
      1. Second item

      | Name | Value |
      | --- | --- |
      | pages | 3 |
      """)
}

// MARK: - DOCX

private func docxMarkdown(
  document: String, numbering: String? = nil, relationships: String? = nil
) throws -> String {
  var parts: [String: Data] = ["word/document.xml": Data(document.utf8)]
  if let numbering { parts["word/numbering.xml"] = Data(numbering.utf8) }
  if let relationships { parts["word/_rels/document.xml.rels"] = Data(relationships.utf8) }
  return try DOCXImporter.markdown(parts: parts)
}

private func docxBody(_ content: String) -> String {
  """
  <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
  <w:document \
  xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
  xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
  <w:body>\(content)</w:body></w:document>
  """
}

@Test("Word headings, paragraphs, and empty paragraphs")
func docxHeadingsAndParagraphs() throws {
  let xml = docxBody(
    """
    <w:p><w:pPr><w:pStyle w:val="Title"/></w:pPr><w:r><w:t>Quarterly Report</w:t></w:r></w:p>
    <w:p><w:pPr><w:pStyle w:val="Heading 2"/></w:pPr><w:r><w:t>Overview</w:t></w:r></w:p>
    <w:p><w:r><w:t>Plain paragraph.</w:t></w:r></w:p>
    <w:p/>
    """)
  #expect(
    try docxMarkdown(document: xml) == """
      # Quarterly Report

      ## Overview

      Plain paragraph.
      """)
}

@Test("Word run styles, hyperlinks, code, and line breaks")
func docxRunStylesLinksAndBreaks() throws {
  let relationships = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://x/styles" Target="styles.xml"/>
    <Relationship Id="rId7" Type="http://x/hyperlink" \
    Target="https://example.com/dash?q=1" TargetMode="External"/>
    </Relationships>
    """
  let xml = docxBody(
    """
    <w:p>
    <w:r><w:t xml:space="preserve">Revenue was </w:t></w:r>
    <w:r><w:rPr><w:b/></w:rPr><w:t>up 12%</w:t></w:r>
    <w:r><w:t xml:space="preserve"> versus </w:t></w:r>
    <w:r><w:rPr><w:i/></w:rPr><w:t>last</w:t></w:r>
    <w:r><w:rPr><w:i/></w:rPr><w:t> year</w:t></w:r>
    <w:r><w:t xml:space="preserve">. See </w:t></w:r>
    <w:hyperlink r:id="rId7"><w:r><w:rPr><w:rStyle w:val="Hyperlink"/></w:rPr>\
    <w:t>the dashboard</w:t></w:r></w:hyperlink>
    <w:r><w:t xml:space="preserve"> and run </w:t></w:r>
    <w:r><w:rPr><w:rStyle w:val="HTMLCode"/></w:rPr><w:t>make build</w:t></w:r>
    <w:r><w:t>.</w:t></w:r>
    <w:r><w:br/><w:t>Second line.</w:t></w:r>
    </w:p>
    """)
  let expected =
    "Revenue was **up 12%** versus *last year*. "
    + "See [the dashboard](https://example.com/dash?q=1) and run `make build`.  \n"
    + "Second line."
  #expect(try docxMarkdown(document: xml, relationships: relationships) == expected)
}

@Test("Word bulleted and numbered lists and quotes")
func docxLists() throws {
  let numbering = """
    <?xml version="1.0" encoding="UTF-8"?>
    <w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
    <w:abstractNum w:abstractNumId="0">
    <w:lvl w:ilvl="0"><w:numFmt w:val="bullet"/></w:lvl>
    <w:lvl w:ilvl="1"><w:numFmt w:val="bullet"/></w:lvl>
    </w:abstractNum>
    <w:abstractNum w:abstractNumId="1">
    <w:lvl w:ilvl="0"><w:numFmt w:val="decimal"/></w:lvl>
    </w:abstractNum>
    <w:num w:numId="2"><w:abstractNumId w:val="0"/></w:num>
    <w:num w:numId="3"><w:abstractNumId w:val="1"/></w:num>
    </w:numbering>
    """
  let xml = docxBody(
    """
    <w:p><w:pPr><w:pStyle w:val="ListParagraph"/><w:numPr><w:ilvl w:val="0"/>\
    <w:numId w:val="2"/></w:numPr></w:pPr><w:r><w:t>First bullet</w:t></w:r></w:p>
    <w:p><w:pPr><w:pStyle w:val="ListParagraph"/><w:numPr><w:ilvl w:val="1"/>\
    <w:numId w:val="2"/></w:numPr></w:pPr><w:r><w:t>Nested bullet</w:t></w:r></w:p>
    <w:p><w:pPr><w:pStyle w:val="Quote"/></w:pPr><w:r><w:t>Estimates only.</w:t></w:r></w:p>
    <w:p><w:pPr><w:pStyle w:val="ListParagraph"/><w:numPr><w:ilvl w:val="0"/>\
    <w:numId w:val="3"/></w:numPr></w:pPr><w:r><w:t>Step one</w:t></w:r></w:p>
    <w:p><w:pPr><w:pStyle w:val="ListParagraph"/><w:numPr><w:ilvl w:val="0"/>\
    <w:numId w:val="3"/></w:numPr></w:pPr><w:r><w:t>Step two</w:t></w:r></w:p>
    """)
  #expect(
    try docxMarkdown(document: xml, numbering: numbering) == """
      - First bullet
        - Nested bullet

      > Estimates only.

      1. Step one
      1. Step two
      """)
}

@Test("Word tables become pipe tables and Markdown syntax is escaped")
func docxTablesAndEscaping() throws {
  let table = docxBody(
    """
    <w:tbl>
    <w:tr><w:tc><w:p><w:r><w:t>Region</w:t></w:r></w:p></w:tc>
    <w:tc><w:p><w:r><w:t>Sales | net</w:t></w:r></w:p></w:tc></w:tr>
    <w:tr><w:tc><w:p><w:r><w:t>EU</w:t></w:r></w:p>\
    <w:p><w:r><w:t>(incl. UK)</w:t></w:r></w:p></w:tc>
    <w:tc><w:p><w:r><w:rPr><w:b/></w:rPr><w:t>1,200</w:t></w:r></w:p></w:tc></w:tr>
    </w:tbl>
    """)
  #expect(
    try docxMarkdown(document: table) == """
      | Region | Sales \\| net |
      | --- | --- |
      | EU<br>(incl. UK) | **1,200** |
      """)

  let escaped = docxBody(
    """
    <w:p><w:r><w:t># not a heading, a * star and [brackets]</w:t></w:r></w:p>
    <w:p><w:r><w:t>2. not a numbered list</w:t></w:r></w:p>
    """)
  #expect(
    try docxMarkdown(document: escaped) == """
      \\# not a heading, a \\* star and \\[brackets\\]

      2\\. not a numbered list
      """)

  let tracked = docxBody(
    """
    <w:p><w:pPr><w:tabs><w:tab w:val="left" w:pos="720"/></w:tabs>\
    <w:rPr><w:b/></w:rPr></w:pPr>
    <w:r><w:t>Kept</w:t></w:r>
    <w:del><w:r><w:delText> removed</w:delText></w:r></w:del>
    <w:ins><w:r><w:t xml:space="preserve"> added</w:t></w:r></w:ins>
    </w:p>
    """)
  #expect(try docxMarkdown(document: tracked) == "Kept added")

  #expect(throws: DOCXImporter.ImportError.missingDocument) {
    try DOCXImporter.markdown(parts: [:])
  }
  #expect(throws: DOCXImporter.ImportError.emptyDocument) {
    try docxMarkdown(document: docxBody("<w:p/>"))
  }
}

// MARK: - PDF layout reconstruction

/// Builds the laid-out lines a PDF page would produce so the Markdown
/// reconstruction can be checked without PDFKit.
private struct PDFPage {
  static let width = 612.0
  static let height = 792.0
  static let left = 72.0
  static let right = 540.0

  var index: Int
  var cursor = 72.0

  init(index: Int = 0) { self.index = index }

  /// `full` lines run to the right margin, which makes the next line a wrap.
  mutating func line(
    _ runs: [PDFImporter.Run],
    size: Double = 12,
    indent: Double = 0,
    gap: Double = 0,
    full: Bool = true,
    top: Double? = nil
  ) -> PDFImporter.Line {
    let text = runs.map(\.text).joined()
    let left = PDFPage.left + indent
    let width = full ? PDFPage.right - left : Double(text.count) * size * 0.5
    let start = top ?? (cursor + gap)
    cursor = start + size * 1.2
    return PDFImporter.Line(
      runs: runs,
      frame: PDFImporter.Frame(
        left: left, right: min(left + width, PDFPage.right), top: start,
        bottom: start + size * 1.2),
      pageIndex: index,
      pageWidth: PDFPage.width,
      pageHeight: PDFPage.height)
  }

  mutating func line(
    _ text: String,
    size: Double = 12,
    bold: Bool = false,
    italic: Bool = false,
    indent: Double = 0,
    gap: Double = 0,
    full: Bool = true,
    top: Double? = nil
  ) -> PDFImporter.Line {
    line(
      [PDFImporter.Run(text: text, size: size, bold: bold, italic: italic)],
      size: size, indent: indent, gap: gap, full: full, top: top)
  }
}

@Test("PDF headings, reflow, hyphenation, and deliberate breaks")
func pdfHeadingsAndReflow() {
  var page = PDFPage()
  let report = [
    page.line("Quarterly Report", size: 24, full: false),
    page.line("Overview", size: 16, gap: 12, full: false),
    page.line("Revenue grew across every region we operate in", gap: 10),
    page.line("during the second quarter.", full: false),
    page.line("Costs stayed flat.", gap: 20, full: false),
  ]
  #expect(
    PDFImporter.markdown(lines: report) == """
      # Quarterly Report

      ## Overview

      Revenue grew across every region we operate in during the second quarter.

      Costs stayed flat.
      """)

  var hyphen = PDFPage()
  #expect(
    PDFImporter.markdown(lines: [
      hyphen.line("The manufacturing process depends on inter-"),
      hyphen.line("changeable parts.", full: false),
    ]) == "The manufacturing process depends on interchangeable parts.")

  var address = PDFPage()
  #expect(
    PDFImporter.markdown(lines: [
      address.line("Acme Corporation", full: false),
      address.line("123 Main Street", full: false),
      address.line("Springfield, IL", full: false),
    ]) == "Acme Corporation  \n123 Main Street  \nSpringfield, IL")
}

@Test("PDF lists, emphasis, links, and bold headings")
func pdfListsAndInlineStyles() {
  var shopping = PDFPage()
  #expect(
    PDFImporter.markdown(lines: [
      shopping.line("Shopping list", size: 18, full: false),
      shopping.line("\u{2022} Apples", gap: 10, full: false),
      shopping.line("\u{2022} Bread", full: false),
      shopping.line("\u{2022} Sourdough", indent: 24, full: false),
      shopping.line("\u{2022} Milk", full: false),
    ]) == """
      # Shopping list

      - Apples
      - Bread
        - Sourdough
      - Milk
      """)

  var recipe = PDFPage()
  #expect(
    PDFImporter.markdown(lines: [
      recipe.line("1. Preheat the oven to 200 degrees and wait"),
      recipe.line("until it beeps.", indent: 18, full: false),
      recipe.line("2. Add the dough.", full: false),
    ]) == "1. Preheat the oven to 200 degrees and wait until it beeps.\n1. Add the dough.")

  var styled = PDFPage()
  #expect(
    PDFImporter.markdown(lines: [
      styled.line(
        [
          PDFImporter.Run(text: "A "),
          PDFImporter.Run(text: "bold", bold: true),
          PDFImporter.Run(text: " and "),
          PDFImporter.Run(text: "italic", italic: true),
          PDFImporter.Run(text: " claim, see "),
          PDFImporter.Run(text: "the docs", link: "https://example.com/docs"),
          PDFImporter.Run(text: "."),
        ], full: false)
    ]) == "A **bold** and *italic* claim, see [the docs](https://example.com/docs).")

  var background = PDFPage()
  #expect(
    PDFImporter.markdown(lines: [
      background.line("Background", bold: true, full: false),
      background.line("The project started in 2019 and has shipped", gap: 8),
      background.line("every quarter since.", full: false),
    ]) == "# Background\n\nThe project started in 2019 and has shipped every quarter since.")
}

@Test("PDF running heads, page breaks, escaping, and ligatures")
func pdfDocumentWideCleanup() {
  var lines: [PDFImporter.Line] = []
  for index in 0..<3 {
    var page = PDFPage(index: index)
    lines.append(page.line("Annual Report 2024", size: 9, full: false, top: 40))
    lines.append(page.line("Body text for page \(index + 1).", full: false, top: 300))
    lines.append(page.line("Page \(index + 1) of 3", size: 9, full: false, top: 745))
  }
  #expect(
    PDFImporter.markdown(lines: lines)
      == "Body text for page 1.\n\nBody text for page 2.\n\nBody text for page 3.")

  var first = PDFPage(index: 0)
  var second = PDFPage(index: 1)
  #expect(
    PDFImporter.markdown(lines: [
      first.line("The committee agreed that the proposal needed"),
      second.line("further review.", full: false, top: 72),
    ]) == "The committee agreed that the proposal needed further review.")

  var escaped = PDFPage()
  #expect(
    PDFImporter.markdown(lines: [
      escaped.line("# not a heading", full: false),
      escaped.line("2 * 3 [see] later", gap: 20, full: false),
    ]) == "\\# not a heading\n\n2 \\* 3 \\[see\\] later")

  var ligatures = PDFPage()
  #expect(
    PDFImporter.markdown(lines: [
      ligatures.line("The \u{FB01}nal of\u{FB02}ine dif\u{00AD}ference", full: false)
    ]) == "The final offline difference")

  var blank = PDFPage()
  #expect(PDFImporter.markdown(lines: []) == "")
  #expect(PDFImporter.markdown(lines: [blank.line("   ", full: false)]) == "")
}

// MARK: - JSON

@Test("JSON objects render as an outline with sections")
func jsonObjectRendering() throws {
  let rendered = try JSONDocumentImporter.render(
    text: """
      {
        "name": "PocketMai",
        "version": 1.5,
        "server": {
          "host": "example.com",
          "ports": [80, 443]
        },
        "flags": [],
        "empty": {},
        "notes": null
      }
      """)
  #expect(
    rendered.text == """
      name: PocketMai
      version: 1.5
      server:
        host: example.com
        ports:
          - 80
          - 443
      flags: []
      empty: {}
      notes: null
      """)
  #expect(
    rendered.sections == [
      JSONDocumentImporter.Section(line: 3, depth: 0, title: "server"),
      JSONDocumentImporter.Section(line: 5, depth: 1, title: "ports"),
    ])
}

@Test("JSON arrays, escapes, key order, numbers, and top-level values")
func jsonValues() throws {
  let rendered = try JSONDocumentImporter.render(
    text: """
      {
        "items": [
          {"name": "a", "value": 1},
          "plain",
          ["x", "y"]
        ],
        "note": "line one\\nline two",
        "emoji": "\\ud83d\\ude00",
        "empty": ""
      }
      """)
  #expect(
    rendered.text == """
      items:
        -
          name: a
          value: 1
        - plain
        -
          - x
          - y
      note:
        line one
        line two
      emoji: \u{1F600}
      empty: ""
      """)
  #expect(rendered.sections == [JSONDocumentImporter.Section(line: 1, depth: 0, title: "items")])
  #expect(
    try JSONDocumentImporter.render(text: "{\"zebra\": 1, \"apple\": 2, \"mango\": 3}").text
      == "zebra: 1\napple: 2\nmango: 3")
  #expect(
    try JSONDocumentImporter.render(text: "{\"a\": 0.30000000000000004, \"b\": -1e10}").text
      == "a: 0.30000000000000004\nb: -1e10")
  #expect(try JSONDocumentImporter.render(text: "42").text == "42")
  #expect(try JSONDocumentImporter.render(text: "{}").text == "{}")
  #expect(
    try JSONDocumentImporter.render(text: "[true, false, null]").text == "- true\n- false\n- null")
  for invalid in ["{\"a\": }", "[1, 2,]", "{} extra", "{\"a\" 1}", "\"unterminated"] {
    #expect(throws: (any Error).self) { try JSONDocumentImporter.render(text: invalid) }
  }
}

// MARK: - Attachments

@Test("Documents become file parts with the right name, type, and note")
func documentAttachments() throws {
  let markdown = try DocumentAttachmentImporter.attachment(
    data: Data("# Notes\n\nhello".utf8), filename: "notes.md")
  #expect(markdown.name == "notes.md")
  #expect(markdown.note == nil)
  #expect(
    markdown.content
      == .file(FileContent(name: "notes.md", mimeType: "text/markdown", text: "# Notes\n\nhello")))

  let json = try DocumentAttachmentImporter.attachment(
    data: Data("{\"a\": [1, 2]}".utf8), filename: "config.json")
  #expect(json.name == "config.txt")
  #expect(json.note == "converted from JSON to an indented outline")
  #expect(
    json.content
      == .file(FileContent(name: "config.txt", mimeType: "text/plain", text: "a:\n  - 1\n  - 2")))

  let word = try DocumentAttachmentImporter.attachment(
    at: fixturesDirectory.appendingPathComponent("sample.docx"))
  #expect(word.name == "sample.md")
  #expect(word.note == "converted from Word to Markdown")
  guard case .file(let file) = word.content else {
    Issue.record("Expected a file part")
    return
  }
  #expect(file.mimeType == "text/markdown")
  #expect(file.text?.hasPrefix("# Fixture Report") == true)
  #expect(word.characterCount == file.text?.count)

  let source = try DocumentAttachmentImporter.attachment(
    data: Data("int main(void) { return 0; }\n".utf8), filename: "main.c")
  #expect(
    source.content
      == .file(
        FileContent(
          name: "main.c", mimeType: "text/x-c", text: "int main(void) { return 0; }\n")))

  #expect(DocumentAttachmentImporter.kind(forFilename: "photo.JPG") == .image)
  #expect(DocumentAttachmentImporter.kind(forFilename: "README") == .text)
  #expect(throws: DocumentImportError.imageRequiresImageImporter("photo.png")) {
    try DocumentAttachmentImporter.attachment(data: Data([1, 2, 3]), filename: "photo.png")
  }
  #expect(throws: DocumentImportError.binaryFile("blob.bin")) {
    try DocumentAttachmentImporter.attachment(data: Data([0x00, 0x01, 0x02]), filename: "blob.bin")
  }
  #expect(throws: DocumentImportError.emptyText("blank.txt")) {
    try DocumentAttachmentImporter.attachment(data: Data("  \n".utf8), filename: "blank.txt")
  }
  #expect(throws: DocumentImportError.fileNotFound("/nonexistent/file.txt")) {
    try DocumentAttachmentImporter.attachment(at: URL(fileURLWithPath: "/nonexistent/file.txt"))
  }
}

@Test("Document kinds prefer content and MIME type over file extensions")
func documentAttachmentContentDetection() {
  #expect(
    DocumentAttachmentImporter.kind(
      for: Data("%PDF-1.7\n".utf8), filename: "download.bin") == .pdf)
  #expect(
    DocumentAttachmentImporter.kind(
      for: Data("<!doctype html><p>Hello</p>".utf8), filename: "download") == .html)
  #expect(
    DocumentAttachmentImporter.kind(
      for: Data("<p>Hello</p>".utf8), filename: "download")
      == .html)
  #expect(
    DocumentAttachmentImporter.kind(
      for: Data("<p>Hello</p>".utf8), filename: "fragment.HTML") == .html)
  #expect(
    DocumentAttachmentImporter.kind(
      for: Data("print('hello')\n".utf8), filename: "script.data", mimeType: "text/x-python")
      == .text)
}

@Test("Copied imports avoid collisions and preserve a file already in place")
func documentAttachmentCopy() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("document-copy-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  let original = directory.appendingPathComponent("notes.html")
  try Data("old".utf8).write(to: original)
  let copied = try DocumentAttachmentImporter.copy(
    data: Data("new".utf8), filename: "notes.html", into: directory)
  #expect(copied.lastPathComponent == "notes-2.html")
  #expect(try Data(contentsOf: original) == Data("old".utf8))
  #expect(try Data(contentsOf: copied) == Data("new".utf8))

  let sameFile = try DocumentAttachmentImporter.copy(
    data: Data("ignored".utf8), filename: copied.lastPathComponent,
    into: directory, sourceURL: copied)
  #expect(sameFile == copied)
  #expect(try Data(contentsOf: copied) == Data("new".utf8))
}

@Test("HTML can attach as source or convert to Markdown")
func htmlDocumentAttachment() throws {
  let data = Data(
    """
    <!doctype html><html><head><meta charset="utf-8"><title>Ignored</title><script>if (a < b) alert('&');</script></head>
    <body><h1>Notes</h1><p>Hello <strong>world</strong>.</p><ul><li>One</li></ul></body></html>
    """.utf8)
  let source = try DocumentAttachmentImporter.attachment(data: data, filename: "notes.dat")
  guard case .file(let sourceFile) = source.content else {
    Issue.record("Expected HTML source")
    return
  }
  #expect(sourceFile.name == "notes.dat")
  #expect(sourceFile.mimeType == "text/html")
  #expect(sourceFile.text?.contains("<strong>world</strong>") == true)

  let markdown = try DocumentAttachmentImporter.attachment(
    data: data, filename: "notes.html", htmlMode: .markdown)
  #expect(markdown.name == "notes.md")
  #expect(markdown.note == "converted from HTML to Markdown")
  guard case .file(let markdownFile) = markdown.content else {
    Issue.record("Expected converted HTML")
    return
  }
  #expect(markdownFile.mimeType == "text/markdown")
  #expect(markdownFile.text == "# Notes\n\nHello **world**.\n\n- One")

  let utf16 = try #require("<p>Wide text</p>".data(using: .utf16))
  #expect(try HTMLImporter.markdown(from: utf16) == "Wide text")
}

// MARK: - EPUB

private let epubContainer = """
  <?xml version="1.0" encoding="UTF-8"?>
  <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
    <rootfiles>
      <rootfile full-path="OEBPS/book.opf" media-type="application/oebps-package+xml"/>
    </rootfiles>
  </container>
  """

private let epubPackage = """
  <?xml version="1.0" encoding="UTF-8"?>
  <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
    <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
      <dc:title>Pocket Book</dc:title>
    </metadata>
    <manifest>
      <item id="c1" href="text/chapter1.xhtml" media-type="application/xhtml+xml"/>
      <item id="c2" href="text/chapter2.xhtml" media-type="application/xhtml+xml"/>
      <item id="css" href="style.css" media-type="text/css"/>
    </manifest>
    <spine>
      <itemref idref="c1"/>
      <itemref idref="c2"/>
    </spine>
  </package>
  """

private let epubChapterOne = """
  <?xml version="1.0" encoding="utf-8"?>
  <html xmlns="http://www.w3.org/1999/xhtml">
    <head><title>Chapter 1</title><link rel="stylesheet" href="../style.css"/></head>
    <body>
      <h1>Chapter One</h1>
      <p>Plain text with <strong>bold</strong> words and a
        <a href="https://example.com">link</a>.</p>
      <ul><li>First item</li><li>Second item</li></ul>
      <blockquote><p>Quoted&nbsp;line&mdash;here.</p></blockquote>
    </body>
  </html>
  """

private let epubChapterTwo = """
  <?xml version="1.0" encoding="utf-8"?>
  <html xmlns="http://www.w3.org/1999/xhtml">
    <body>
      <h2>Notes</h2>
      <pre><code>print("hi")</code></pre>
      <table>
        <tr><th>Name</th><th>Value</th></tr>
        <tr><td>pages</td><td>3</td></tr>
      </table>
    </body>
  </html>
  """

private func sampleEPUB() -> Data {
  ZipArchiveWriter.archive(entries: [
    (path: "mimetype", data: Data("application/epub+zip".utf8)),
    (path: "META-INF/container.xml", data: Data(epubContainer.utf8)),
    (path: "OEBPS/book.opf", data: Data(epubPackage.utf8)),
    (path: "OEBPS/text/chapter1.xhtml", data: Data(epubChapterOne.utf8)),
    (path: "OEBPS/text/chapter2.xhtml", data: Data(epubChapterTwo.utf8)),
    (path: "OEBPS/style.css", data: Data("p { margin: 0 }".utf8)),
  ])
}

@Test("An EPUB book converts to Markdown in spine order")
func epubConvertsToMarkdown() throws {
  let markdown = try EPUBImporter.markdown(from: sampleEPUB())
  #expect(
    markdown == """
      # Pocket Book

      # Chapter One

      Plain text with **bold** words and a [link](https://example.com).

      - First item
      - Second item

      > Quoted line—here.

      ## Notes

      ```
      print("hi")
      ```

      | Name | Value |
      | --- | --- |
      | pages | 3 |
      """)
}

@Test("EPUB import reports damaged books and empty books")
func epubImportFailures() throws {
  #expect(throws: EPUBImporter.ImportError.unreadableArchive) {
    try EPUBImporter.markdown(from: Data("not a zip archive at all".utf8))
  }
  #expect(throws: EPUBImporter.ImportError.missingPackage) {
    try EPUBImporter.markdown(parts: ["META-INF/container.xml": Data(epubContainer.utf8)])
  }
  #expect(throws: EPUBImporter.ImportError.emptyDocument) {
    try EPUBImporter.markdown(parts: [
      "book.opf": Data(
        """
        <package xmlns="http://www.idpf.org/2007/opf">
          <manifest><item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/></manifest>
          <spine><itemref idref="c1"/></spine>
        </package>
        """.utf8),
      "c1.xhtml": Data("<html><body><p>   </p></body></html>".utf8),
    ])
  }
}

@Test("Unknown HTML entities survive as text instead of failing the parse")
func epubEntityNormalization() throws {
  let normalized = String(
    decoding: XHTMLEntities.normalized(Data("R&D &nbsp; &unknown; &amp; &#x41;".utf8)),
    as: UTF8.self)
  #expect(normalized == "R&amp;D &#160; &amp;unknown; &amp; &#x41;")
}

@Test("An EPUB attaches as a converted Markdown file")
func epubDocumentAttachment() throws {
  let attachment = try DocumentAttachmentImporter.attachment(
    data: sampleEPUB(), filename: "pocket book.epub")
  #expect(attachment.name == "pocket book.md")
  #expect(attachment.note == "converted from EPUB to Markdown")
  #expect(DocumentAttachmentImporter.kind(forFilename: "Book.EPUB") == .epub)
  guard case .file(let file) = attachment.content else {
    Issue.record("Expected a file part")
    return
  }
  #expect(file.mimeType == "text/markdown")
  #expect(file.text?.hasPrefix("# Pocket Book") == true)
}
