# Pindrop Orukeet UI validation

Production source: 5be066c85ddaa1a3bf03e8259f51806de5530445. PR head 870eb5f3c3a2d16889b68bd51f9d1bc98a518684 only moves README instructions; application code is identical.

The full application was built with Xcode 26.6. For these screenshots, the existing isolated settings fixture hosts the unchanged ModelsSettingsView and actual ModelManager, using a test defaults suite and temporary model directories. The complete validation-only host patch is adjacent. This host is outside the upstream PR.

On macOS 26.4.1 arm64, the real model row appears, clicking Download fetches the pinned Hugging Face artifact, progress advances, and the row reaches Installed. No microphone or Accessibility permission was requested or granted. Recognition itself is covered by the separate actual-engine native/offline tests, not claimed from this settings host.

- Catalog: Pindrop-models-catalog.png
- Download progress: Pindrop-download-progress.png
- Installed: Pindrop-model-installed.png

Full app/shared/iOS validation: https://github.com/Nathan-Roll1/pindrop/actions/runs/35281323478
Network-denied actual recognition: https://github.com/Nathan-Roll1/pindrop/actions/runs/35282566516
UI host build: https://github.com/Nathan-Roll1/pindrop/actions/runs/35282904814
