#if os(Windows)
import Foundation
import WinSDK

extension FileSystem {
    static func directory(_ root: URL) -> DirectoryEntries? {DirectoryEntries(root)}
}

/// A single directory cursor avoids retaining every child before scanning.
final class DirectoryEntries {
    private let root: URL
    private var handle: HANDLE?
    private var data=WIN32_FIND_DATAW()
    private var first=true
    private(set) var currentIsDirectory=false
    private(set) var unreadable=Set<String>()

    init(_ root:URL) {
        self.root=root
        let path=root.path.replacingOccurrences(of:"/",with:"\\")
        let pattern=path+(path.hasSuffix("\\") ? "*" : "\\*")
        handle=pattern.withCString(encodedAs:UTF16.self) {
            FindFirstFileExW($0,FindExInfoBasic,&data,FindExSearchNameMatch,nil,0)
        }
        if handle==INVALID_HANDLE_VALUE || handle==nil {
            let error=GetLastError()
            if error != DWORD(ERROR_FILE_NOT_FOUND) && error != DWORD(ERROR_NO_MORE_FILES) {
                unreadable.insert(root.path)
            }
            handle=nil
        }
    }

    deinit {if let handle {FindClose(handle)}}

    func skipDescendants() {}

    func nextObject() -> Any? {
        while let open=handle {
            if first {first=false}
            else if !FindNextFileW(open,&data) {
                if GetLastError() != DWORD(ERROR_NO_MORE_FILES) {unreadable.insert(root.path)}
                FindClose(open);handle=nil
                return nil
            }
            let name=withUnsafePointer(to:&data.cFileName) {
                $0.withMemoryRebound(to:WCHAR.self,capacity:260) {String(decodingCString:$0,as:UTF16.self)}
            }
            let attributes=data.dwFileAttributes
            let link=attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) != 0
                && (data.dwReserved0==0xA000_000C || data.dwReserved0==0xA000_0003)
            if name.hasPrefix(".") || attributes & DWORD(FILE_ATTRIBUTE_HIDDEN) != 0 || link {continue}
            currentIsDirectory=attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0
            return root.appendingPathComponent(name,isDirectory:currentIsDirectory)
        }
        return nil
    }
}
#endif
