import Foundation

/// Function pointers from the private MultitouchSupport framework, resolved once at run time.
/// The framework has no public headers; names and C signatures are the ones the system exports.
struct MultitouchAPI {
    typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
    typealias DeviceID = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt64>) -> Int32
    typealias IsBuiltIn = @convention(c) (UnsafeMutableRawPointer) -> Bool
    typealias ActuatorCreate = @convention(c) (UInt64) -> Unmanaged<CFTypeRef>?
    typealias ActuatorOpenClose = @convention(c) (CFTypeRef) -> Int32
    /// (description, unused flags) → actuation object owned by the caller.
    typealias ActuationCreate = @convention(c) (CFDictionary, Int32) -> UnsafeMutableRawPointer?
    /// (actuation, actuator, unused, strength 0…1, unused).
    typealias Actuate = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer, UInt32, Float, Float) -> Int32
    typealias FrameCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
    typealias RegisterCallback = @convention(c) (UnsafeMutableRawPointer, FrameCallback) -> Void
    typealias DeviceStart = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void
    typealias DeviceStop = @convention(c) (UnsafeMutableRawPointer) -> Void

    let createList: CreateList
    let deviceID: DeviceID
    let isBuiltIn: IsBuiltIn?
    let actuatorCreate: ActuatorCreate
    let actuatorOpen: ActuatorOpenClose
    let actuatorClose: ActuatorOpenClose?
    let actuationCreate: ActuationCreate
    let actuate: Actuate
    let registerCallback: RegisterCallback?
    let unregisterCallback: RegisterCallback?
    let deviceStart: DeviceStart?
    let deviceStop: DeviceStop?

    static let shared: MultitouchAPI? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW) else { return nil }
        func load<T>(_ name: String, _: T.Type) -> T? { dlsym(handle, name).map { unsafeBitCast($0, to: T.self) } }
        guard let createList = load("MTDeviceCreateList", CreateList.self),
              let deviceID = load("MTDeviceGetDeviceID", DeviceID.self),
              let actuatorCreate = load("MTActuatorCreateFromDeviceID", ActuatorCreate.self),
              let actuatorOpen = load("MTActuatorOpen", ActuatorOpenClose.self),
              let actuationCreate = load("MTActuationCreateFromDictionary", ActuationCreate.self),
              let actuate = load("MTActuationActuate", Actuate.self) else { return nil }
        return MultitouchAPI(
            createList: createList, deviceID: deviceID, isBuiltIn: load("MTDeviceIsBuiltIn", IsBuiltIn.self),
            actuatorCreate: actuatorCreate, actuatorOpen: actuatorOpen, actuatorClose: load("MTActuatorClose", ActuatorOpenClose.self),
            actuationCreate: actuationCreate, actuate: actuate,
            registerCallback: load("MTRegisterContactFrameCallback", RegisterCallback.self),
            unregisterCallback: load("MTUnregisterContactFrameCallback", RegisterCallback.self),
            deviceStart: load("MTDeviceStart", DeviceStart.self), deviceStop: load("MTDeviceStop", DeviceStop.self))
    }()

    /// All multitouch devices with their ids, built-in first.
    func devices() -> (list: CFArray, entries: [(device: UnsafeMutableRawPointer, id: UInt64)])? {
        guard let list = createList()?.takeRetainedValue() else { return nil }
        var entries: [(UnsafeMutableRawPointer, UInt64, Bool)] = []
        for i in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, i) else { continue }
            let device = UnsafeMutableRawPointer(mutating: raw)
            var id: UInt64 = 0
            if deviceID(device, &id) == 0 { entries.append((device, id, isBuiltIn?(device) ?? false)) }
        }
        return (list, entries.sorted { $0.2 && !$1.2 }.map { ($0.0, $0.1) })
    }
}
