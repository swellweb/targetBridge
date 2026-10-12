enum TBOutputMuteRestoration {
    static func mute(
        elements: [UInt32],
        read: (UInt32) -> Bool?,
        write: (UInt32, Bool) -> Bool
    ) -> [UInt32] {
        elements.filter { element in
            guard read(element) == false else { return false }
            return write(element, true)
        }
    }

    static func restore(
        changedElements: [UInt32],
        read: (UInt32) -> Bool?,
        write: (UInt32, Bool) -> Bool
    ) {
        for element in changedElements where read(element) == true {
            _ = write(element, false)
        }
    }
}
