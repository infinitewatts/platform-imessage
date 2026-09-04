import IMDatabase
import Testing
@testable import IMessage

@Test func approvedEvidenceKeepsExactDatabaseDestinationAndOwnership() throws {
    let row = try MappedMessageRow(object: ["ROWID": 12, "guid": "fixture-message", "threadID": "actual-thread",
                                          "is_from_me": 0, "error": 7, "date_edited": 123,
                                          "associated_message_guid": "p:0/fixture-target", "associated_message_type": 2001])
    let evidence = PlatformAPI.approvedEvidence(row: row, text: "fixture", sent: false, plainSinglePart: true)
    #expect(evidence.messageID == "fixture-message")
    #expect(evidence.threadID == "actual-thread")
    #expect(!evidence.owned)
    #expect(!evidence.sent)
    #expect(evidence.error == 7)
    #expect(evidence.edited == 123)
    #expect(evidence.associatedID == "p:0/fixture-target")
    #expect(evidence.associatedType == 2001)
}

@Test func approvedEvidenceRetractionRequiresExplicitMarker() throws {
    for object: [String: Any] in [[:], ["date_retracted": 1], ["was_detonated": 1]] {
        var values = object
        values["ROWID"] = 12
        values["guid"] = "fixture-message"
        let row = try MappedMessageRow(object: values)
        let evidence = PlatformAPI.approvedEvidence(row: row, text: nil, sent: true, plainSinglePart: false)
        #expect(evidence.retracted == !object.isEmpty)
        #expect(evidence.threadID.isEmpty)
        #expect(!evidence.plainSinglePart)
    }
}
