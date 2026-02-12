import Foundation
import SQLite3

public struct SubtaskInfo: Sendable {
    public let parentID: String?
    public let displayOrder: Int
}

public struct ListSharingInfo: Sendable {
    public let isShared: Bool
    public let sharingStatus: Int
}

public final class SubtaskStore {
    private let databasePaths: [String]
    
    public init() {
        let storesPath = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Group Containers/group.com.apple.reminders/Container_v1/Stores")
        let fileManager = FileManager.default
        var paths: [String] = []
        
        if let enumerator = fileManager.enumerator(atPath: storesPath) {
            while let file = enumerator.nextObject() as? String {
                if file.hasSuffix(".sqlite") {
                    paths.append((storesPath as NSString).appendingPathComponent(file))
                }
            }
        }
        self.databasePaths = paths
    }
    
    public func fetchSubtaskInfo() -> [String: SubtaskInfo] {
        var results: [String: SubtaskInfo] = [:]
        
        for path in databasePaths {
            var db: OpaquePointer?
            if sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
                let query = """
                SELECT r1.ZDACALENDARITEMUNIQUEIDENTIFIER, r2.ZDACALENDARITEMUNIQUEIDENTIFIER, r1.ZICSDISPLAYORDER
                FROM ZREMCDREMINDER r1
                LEFT JOIN ZREMCDREMINDER r2 ON r1.ZPARENTREMINDER = r2.Z_PK
                WHERE r1.ZDACALENDARITEMUNIQUEIDENTIFIER IS NOT NULL;
                """
                
                var statement: OpaquePointer?
                if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
                    while sqlite3_step(statement) == SQLITE_ROW {
                        let id = String(cString: sqlite3_column_text(statement, 0))
                        let parentID = sqlite3_column_text(statement, 1).map { String(cString: $0) }
                        let order = Int(sqlite3_column_int(statement, 2))
                        
                        results[id] = SubtaskInfo(parentID: parentID, displayOrder: order)
                    }
                    sqlite3_finalize(statement)
                }
                sqlite3_close(db)
            }
        }
        return results
    }
    
    public func fetchSharingInfo() -> [String: ListSharingInfo] {
        var results: [String: ListSharingInfo] = [:]
        
        for path in databasePaths {
            var db: OpaquePointer?
            if sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
                // We use ZCKIDENTIFIER to map back to EventKit's calendarIdentifier
                // In some cases ZIDENTIFIER (BLOB) might be needed if ZCKIDENTIFIER is null.
                let query = "SELECT ZCKIDENTIFIER, ZSHARINGSTATUS FROM ZREMCDBASELIST WHERE ZCKIDENTIFIER IS NOT NULL;"
                
                var statement: OpaquePointer?
                if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
                    while sqlite3_step(statement) == SQLITE_ROW {
                        let id = String(cString: sqlite3_column_text(statement, 0))
                        let status = Int(sqlite3_column_int(statement, 1))
                        results[id] = ListSharingInfo(isShared: status != 0, sharingStatus: status)
                    }
                    sqlite3_finalize(statement)
                }
                sqlite3_close(db)
            }
        }
        return results
    }
}
