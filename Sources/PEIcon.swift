import AppKit

// Read-only extraction of RT_GROUP_ICON/RT_ICON resources; all offsets are bounded.
enum PEIcon {
    static func image(at url: URL) -> NSImage? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        func u16(_ i: Int) -> Int? { guard i >= 0, i <= data.count - 2 else { return nil }; return Int(data[i]) | Int(data[i+1]) << 8 }
        func u32(_ i: Int) -> Int? { guard let a = u16(i), let b = u16(i+2) else { return nil }; return a | b << 16 }
        guard let pe = u32(60), let sections = u16(pe+6), sections <= 96, let optionalSize = u16(pe+20), let magic = u16(pe+24), [0x20b, 0x10b].contains(magic), let resourceRVA = u32(pe+24+(magic == 0x20b ? 112 : 96)+16), resourceRVA > 0 else { return nil }
        func offset(_ rva: Int) -> Int? {
            for section in 0..<sections {
                let i = pe+24+optionalSize+section*40
                guard let size = u32(i+8), let virtual = u32(i+12), let rawSize = u32(i+16), let raw = u32(i+20) else { return nil }
                if rva >= virtual, rva-virtual < max(size, rawSize), rva-virtual < rawSize { let n = raw+rva-virtual; return n < data.count ? n : nil }
            }; return nil
        }
        guard let base = offset(resourceRVA) else { return nil }
        func entries(_ relative: Int) -> [(Int, Int)] {
            let i = base+relative
            guard let named = u16(i+12), let count = u16(i+14), named+count <= 4096 else { return [] }
            return (0..<(named+count)).compactMap { n in
                guard let key = u32(i+16+n*8), let value = u32(i+20+n*8) else { return nil }; return (key, value)
            }
        }
        func blob(_ value: Int, depth: Int = 0) -> Data? {
            guard depth < 4 else { return nil }
            if value & 0x80000000 != 0 { guard let first = entries(value & 0x7fffffff).first else { return nil }; return blob(first.1, depth: depth+1) }
            guard let rva = u32(base+value), let size = u32(base+value+4), size > 0, size <= 12_000_000, let start = offset(rva), start <= data.count-size else { return nil }
            return data.subdata(in: start..<start+size)
        }
        let types = entries(0)
        guard let groupType = types.first(where: { $0.0 == 14 }), let iconType = types.first(where: { $0.0 == 3 }), groupType.1 & 0x80000000 != 0, iconType.1 & 0x80000000 != 0, let group = blob(groupType.1), group.count >= 6 else { return nil }
        let icons = entries(iconType.1 & 0x7fffffff)
        let count = Int(group[4]) | Int(group[5]) << 8
        guard count > 0, count <= 256, group.count >= 6+count*14 else { return nil }
        var selected: [(Data, Data)] = []
        for n in 0..<count {
            let i = 6+n*14, id = Int(group[i+12]) | Int(group[i+13]) << 8
            if let resource = icons.first(where: { $0.0 == id }), let bytes = blob(resource.1) { selected.append((group.subdata(in: i..<i+8), bytes)) }
        }
        guard !selected.isEmpty else { return nil }
        var result = Data([0,0,1,0,UInt8(selected.count & 255),UInt8(selected.count >> 8)])
        var position = 6+selected.count*16
        for (header, bytes) in selected {
            result.append(header)
            for value in [bytes.count, position] { var little = UInt32(value).littleEndian; withUnsafeBytes(of: &little) { result.append(contentsOf: $0) } }
            position += bytes.count
        }
        for (_, bytes) in selected { result.append(bytes) }
        return NSImage(data: result)
    }
}
