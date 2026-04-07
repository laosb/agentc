import Crypto
import Foundation

func sha256Hex(_ string: String) -> String {
  let data = Data(string.utf8)
  let digest = SHA256.hash(data: data)
  return digest.map { String(format: "%02x", $0) }.joined()
}
