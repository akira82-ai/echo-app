# Echo release workflow

- When the user says “提交” without narrowing the scope, run the full release workflow: analyze changes, assess README updates, synchronize relevant issues, increment version and build, build and verify signed release assets and appcast, then commit, push, and publish the release. An explicit commit-only or no-release request overrides this shorthand.
- Ordinary development, commits, and pushes must not update `appcast.xml`.
- Only when publishing a new release: increment the version and build number, build and code-sign the installation package, then use Sparkle tooling to generate the appcast and sign the update archive. Verify the exact archive against the appcast and the client's public key before publishing. The appcast must contain the version/build, download URL, archive size, and update signature.
- Include appcast generation and signature verification in the release scripts. Do not hand-edit generated, verified release XML; regenerate and reverify it after changes, and re-sign any changed archive. Never overwrite a published update archive.
- Upload the verified installation package and `appcast.xml` to GitHub Release. Ensure the stable feed URL configured in shipped clients serves the latest appcast and its referenced archive is accessible.
- If an appcast was already generated and verified locally, first check that it matches the exact package being released; do not assume it still matches after a rebuild.
- Do not replace `/Applications/Echo.app`, stop the running app, or launch the new app during commits or releases unless explicitly requested. The user obtains new versions through the in-app updater.
- Report signing, verification, upload, or feed configuration failures explicitly; never claim an update is available without verifying publication.
