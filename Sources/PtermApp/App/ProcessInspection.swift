import Darwin
import Foundation

enum ProcessInspection {
    static func currentDirectory(pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(MemoryLayout<proc_vnodepathinfo>.stride))
        guard size == Int32(MemoryLayout<proc_vnodepathinfo>.stride) else { return nil }
        let path = info.pvi_cdir.vip_path
        return withUnsafePointer(to: path) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: path)) {
                String(cString: $0)
            }
        }
    }
}
