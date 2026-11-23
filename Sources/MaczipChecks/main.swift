import Foundation

Harness.suite("러너") {
    Harness.expect(1 + 1 == 2, "러너 자체 점검")
}

zipCryptoChecks()
filenameCodecChecks()
pathChecks()
deflateChecks()
zipWriterChecks()
zipReaderChecks()
archiverChecks()
reviewFixChecks()
passwordEntryChecks()

Harness.finish()
