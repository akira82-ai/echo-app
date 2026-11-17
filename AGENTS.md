# Echo release workflow

- After a release build passes verification, install the built `dist/Echo.app` at `/Applications/Echo.app`, replacing the previous installed version.
- Stop any running Echo process before replacing its bundle. Preserve a recoverable backup of an existing installation, copy the complete bundle, and verify the installed version, build number, and code signature.
- Report installation or permission failures explicitly. Never claim the installed app was updated without checking it.
