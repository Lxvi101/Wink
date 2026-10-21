class Wink < Formula
  desc "Lightning-fast macOS screenshots & AI vision analysis"
  homepage "https://github.com/openclaw/Peekaboo"
  url "https://github.com/openclaw/Peekaboo/releases/download/v4.3.1/wink-macos-universal.tar.gz"
  sha256 "e26f9782d22ae346821c91dc454a50797c045d20a7eece7ede160bd94f165ffd"
  license "MIT"

  # macOS Sequoia (15.0) or later required
  depends_on macos: :sequoia

  def install
    bin.install "wink", *Dir["libswiftCompatibility*.dylib"]
  end

  def caveats
    <<~EOS
      Wink requires Screen Recording permission to capture screenshots.

      To grant permission:
      1. Open System Settings > Privacy & Security > Screen & System Audio Recording
      2. Enable access for your Terminal application

      For AI analysis features, configure your AI providers:
        export WINK_AI_PROVIDERS="openai/gpt-5.1,anthropic/claude-sonnet-4.5"
        export OPENAI_API_KEY="your-api-key"

      Or create a config file:
        wink config init
    EOS
  end

  test do
    # Test that the binary runs and returns version
    assert_match "Wink", shell_output("#{bin}/wink --version")

    # Test help command
    assert_match(/\AUsage\n\s+wink\b/, shell_output("#{bin}/wink --help"))
  end
end
