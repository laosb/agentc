// The agentc Toolkit, mounted read-only by the host at /agent-isolation/toolkit.
//
// It exists so a container is never completely without tools: an image with
// nothing but a shell still gets a curl for `prepare.sh` to install with, and a
// set of CA roots to verify the connection against. The image always wins where
// it has an opinion — the toolkit's binaries sit at the end of PATH, and its CA
// bundle is only pointed at when the image ships no trust store of its own.

#if canImport(FoundationEssentials) && canImport(Musl)
  import Musl

  enum Toolkit {
    static let root = "/agent-isolation/toolkit"
    static let binDirectory = "\(root)/bin"
    static let caBundle = "\(root)/share/ca-certificates.crt"

    /// Trust store locations, in the order they are probed.
    ///
    /// A hashed directory counts as much as a bundle file: either way the image
    /// has roots of its own and the toolkit should keep out of the way.
    static let systemTrustStores = [
      "/etc/ssl/certs/ca-certificates.crt",  // Debian, Ubuntu, Alpine
      "/etc/pki/tls/certs/ca-bundle.crt",  // Fedora, RHEL
      "/etc/ssl/ca-bundle.pem",  // openSUSE
      "/etc/ssl/cert.pem",  // Alpine, BSD
      "/etc/ssl/certs",  // hashed directory
    ]

    /// Put the toolkit's binaries at the end of `PATH`.
    ///
    /// Last place is the point: `curl` resolves to the image's own build wherever
    /// there is one, and to the toolkit's only where there is not.
    static func appendToPath(_ path: inout String) {
      guard access(binDirectory, X_OK) == 0 else { return }
      path = "\(path):\(binDirectory)"
    }

    /// Point TLS clients at the bundled roots, but only on an image that has none.
    ///
    /// Without this, HTTPS fails outright on a minimal image — including the
    /// `curl … | bash` line that nearly every agent installer is built around.
    /// An image that ships a trust store keeps it, so a privately-trusted CA
    /// added to the image goes on working.
    static func exportCABundleIfImageHasNone() {
      guard access(caBundle, R_OK) == 0 else { return }
      guard !systemTrustStores.contains(where: { access($0, F_OK) == 0 }) else { return }

      // curl, OpenSSL and git each read their own variable.
      setenv("CURL_CA_BUNDLE", caBundle, 0)
      setenv("SSL_CERT_FILE", caBundle, 0)
      setenv("GIT_SSL_CAINFO", caBundle, 0)
    }
  }
#endif
