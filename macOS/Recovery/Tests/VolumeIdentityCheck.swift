import Foundation

@main struct VolumeIdentityCheck {
  static func main() {
    let mark = Data("aurora-mark".utf8)
    precondition(!VolumeIdentity.showsVolume(icon: mark, auroraMark: mark))
    precondition(VolumeIdentity.showsVolume(icon: Data("fedora".utf8), auroraMark: mark))
    precondition(VolumeIdentity.showsVolume(icon: nil, auroraMark: mark))
    precondition(VolumeIdentity.showsVolume(icon: Data(), auroraMark: mark))
    precondition(VolumeIdentity.showsVolume(icon: mark, auroraMark: nil))
  }
}
