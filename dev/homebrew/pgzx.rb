# Homebrew formula for the pgzx command and project templates.
#
# This file is a template: `tools/build-dist.sh` publishes the per-target
# `pgzx-cli-<tag>-<target>.tar.gz` archives. Render `version` and the four
# `sha256` values for a release, then copy the result to
# `barddoo/homebrew-tap/Formula/pgzx.rb`.
class Pgzx < Formula
  desc "Zig PostgreSQL extension development helpers and project templates"
  homepage "https://github.com/barddoo/pgzx"
  version "X.Y.Z"
  license "Apache-2.0"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/barddoo/pgzx/releases/download/v#{version}/pgzx-cli-v#{version}-aarch64-macos.tar.gz"
      sha256 "REPLACE_WITH_MACOS_ARM_SHA256"
    else
      url "https://github.com/barddoo/pgzx/releases/download/v#{version}/pgzx-cli-v#{version}-x86_64-macos.tar.gz"
      sha256 "REPLACE_WITH_MACOS_X86_64_SHA256"
    end
  end

  on_linux do
    if Hardware::CPU.arm?
      url "https://github.com/barddoo/pgzx/releases/download/v#{version}/pgzx-cli-v#{version}-aarch64-linux-musl.tar.gz"
      sha256 "REPLACE_WITH_LINUX_ARM_SHA256"
    else
      url "https://github.com/barddoo/pgzx/releases/download/v#{version}/pgzx-cli-v#{version}-x86_64-linux-musl.tar.gz"
      sha256 "REPLACE_WITH_LINUX_X86_64_SHA256"
    end
  end

  depends_on "krb5"
  depends_on "openssl@3"
  depends_on "zig"

  def install
    bin.install Dir["bin/*"]

    (share/"pgzx").install "share/pgzx/install-zig.sh", "share/pgzx/VERSION"
    (share/"pgzx/templates").install Dir["share/pgzx/templates/*"]
  end

  def caveats
    <<~EOS
      pgzx needs PostgreSQL with development headers:
        brew install postgresql@19 && brew link --force postgresql@19
      Check the setup with:
        pgzx doctor
    EOS
  end

  test do
    assert_match "pgzx", shell_output("#{bin}/pgzx help")
    system "#{bin}/pgzx", "doctor"
  end
end
