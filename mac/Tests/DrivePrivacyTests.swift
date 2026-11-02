import Foundation
import Testing
@testable import CloudNestCore

@Test func driveUploadRefusesSharedUnownedTrashedUnknownAndSharedDriveFolders() throws {
    let valid: [String: Any] = ["mimeType": "application/vnd.google-apps.folder", "ownedByMe": true, "shared": false, "trashed": false]
    try DriveClient.validatePrivateFolderMetadata(JSONSerialization.data(withJSONObject: valid))
    for (key, value) in [("shared", true as Any), ("ownedByMe", false as Any), ("trashed", true as Any), ("driveId", "shared-drive" as Any), ("mimeType", "application/octet-stream" as Any)] {
        var changed = valid; changed[key] = value
        #expect(throws: (any Error).self) { try DriveClient.validatePrivateFolderMetadata(JSONSerialization.data(withJSONObject: changed)) }
    }
    for key in ["shared", "ownedByMe", "trashed", "mimeType"] {
        var unknown = valid; unknown.removeValue(forKey: key)
        #expect(throws: (any Error).self) { try DriveClient.validatePrivateFolderMetadata(JSONSerialization.data(withJSONObject: unknown)) }
    }
}
