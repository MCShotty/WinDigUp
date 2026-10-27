# Control Panel and quick launcher

The shortcut panel uses a two-row home: search plus up to six pinned/recent app icons. Pin an app from its details. General settings offer unpinning, recent-app visibility and clearing. Only native app IDs and acceptance times are stored in the local recent-app file (64 entries, 90-day retention). Pins stay in the existing settings file. Hidden or missing apps cannot launch from the strip; temporarily missing pins remain editable.

Classic Control Panel applets and task links share Settings search and the `settings:` prefix. The source label distinguishes them from modern Settings pages. Search `settings: classic Sound` for the classic Sound applet. Windows may redirect a destination on newer releases.

Discovery runs on COM-initialized background threads. It enumerates the Control Panel known folder and feature-detects the All Tasks Shell namespace. The latter is version-dependent. When unavailable, a small set of documented page links is offered only for discovered parent applets. Source failures retain cached records. Shell notifications, startup, stale-opening checks and manual refresh schedule catalog updates; queries do not enumerate the Shell. Task activation invokes the exact selected Shell item, so Windows can show confirmations or UAC. Discovery never executes task commands.

Native catalog/icon data is under the base index's `windows-settings/` directory. Semantic documents continue to use the accelerator-scoped `windows-settings.sqlite`, existing 512-token profile and query-vector cache. Model/runtime/dimension/prompt identities and existing file/application indexes remain unchanged.

## Copilot key

Windows requires a signed package identity and the `com.microsoft.windows.copilotkeyprovider` extension. This implementation adds an external-location identity package to the existing NSIS installer. A small provider executable opens the same WinDigUp single instance with `--show-panel`; ordinary Start-menu activation keeps its existing full-window route. The user selects WinDigUp in Windows' Copilot-key setting; installation does not change that choice.

Build signing inputs:
- `DIGUP_MSIX_PFX_BASE64`: the Windows code-signing certificate and private key as a PFX, supplied through a protected secret.
- `DIGUP_MSIX_PFX_PASSWORD`, `DIGUP_MSIX_PUBLISHER` and `DIGUP_MSIX_TIMESTAMP_URL`: matching password, certificate subject and timestamp server.
- `DIGUP_MSIX_VERSION`: a monotonically increasing four-component identity-package version. Keep package name, publisher and application ID stable across upgrades.

The Tauri updater key is unrelated to Windows certificate trust. Without Windows signing credentials, the normal installer builds without a Copilot identity. Registration failures do not block ordinary search. CI uses an ephemeral self-signed certificate and explicitly labels its installer as test-signed. The installer never trusts certificates automatically. The hosted registration test imports its ephemeral public certificate into the disposable runner's LocalMachine TrustedPeople store only. The supplied public test certificate must be deliberately trusted by a tester before its package can register; it is not a generally trusted production signing identity.

Native installed tests verify registration, provider activation, compact-panel geometry and existing app/Settings paths. Hosted Windows Server checks cannot establish visibility in a physical Windows 11 Copilot picker or hardware-key delivery. Test that separately on supported Windows 11 updates, including managed policy, cold/warm activation, upgrades and uninstall. The disposable CI fixture registers an executable Control Panel applet and its task XML, discovers them through the real Shell, and checks launch acceptance and lifetime. It cleans only its generated registry keys. Physical GPU/NPU and screen-reader/mixed-DPI validation remain separate.

Microsoft references: [Copilot-key providers](https://learn.microsoft.com/windows/apps/develop/windows-integration/microsoft-copilot-key-provider), [external-location identity](https://learn.microsoft.com/windows/apps/desktop/modernize/grant-identity-to-nonpackaged-apps), [Control Panel tasks](https://learn.microsoft.com/windows/win32/shell/creating-searchable-task-links).

Updates keep identity registration stable when the same package is already registered; a changed package or moved installation must use a higher identity version. Registration errors retain the existing identity rather than deleting it to force a retry. Installing a build explicitly lacking signed identity unregisters this product's matching publisher package so the picker does not retain a broken launcher. Pin/recent records and file indexes are independent of package registration.
