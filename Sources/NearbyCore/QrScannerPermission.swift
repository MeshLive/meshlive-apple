/// B1.1: the camera authorization behind the QR scanner, one honest state per gate. The scanner asks once when the
/// state is still unknown to the system, scans when allowed, and explains without leaving a black view otherwise.
public enum QrScannerCamera: Equatable {
    case authorized, denied, restricted, notDetermined, unknown

    /// The DEBUG launch fixture (`-NearbyFixtureCameraPermission`); anything else is nil.
    public init?(fixture: String) {
        switch fixture {
        case "authorized": self = .authorized
        case "denied": self = .denied
        case "restricted": self = .restricted
        case "notDetermined": self = .notDetermined
        case "unknown": self = .unknown
        default: return nil
        }
    }
}

public enum QrScannerGate: Equatable {
    case scan, request
    case blocked(opensSettings: Bool)
}

public enum QrScannerPermission {
    public static let prompt = "Point the camera at the other person's code"

    public static func gate(_ camera: QrScannerCamera) -> QrScannerGate {
        switch camera {
        case .authorized: return .scan
        case .notDetermined: return .request
        case .denied: return .blocked(opensSettings: true)
        case .restricted, .unknown: return .blocked(opensSettings: false)
        }
    }

    public static func message(_ camera: QrScannerCamera, mac: Bool) -> String {
        switch camera {
        case .authorized:
            return ""
        case .notDetermined:
            return "MeshLive needs the camera to scan the other phone's code. Tap Scan again and allow the camera."
        case .denied:
            if mac {
                return "Camera access is off for MeshLive, so it cannot scan the code. Allow the camera in System Settings > Privacy & Security > Camera."
            }
            return "Camera access is off for MeshLive, so it cannot scan the code. Allow the camera in Settings > MeshLive."
        case .restricted:
            if mac {
                return "Camera access is restricted on this Mac, so MeshLive cannot scan the code. Show them your code instead."
            }
            return "Camera access is restricted on this phone, so MeshLive cannot scan the code. Show them your code instead."
        case .unknown:
            return "The camera is not available right now, so MeshLive cannot scan the code. Show them your code instead."
        }
    }
}
