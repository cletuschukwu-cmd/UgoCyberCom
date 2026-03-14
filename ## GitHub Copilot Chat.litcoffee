## GitHub Copilot Chat

- Extension: 0.38.2 (prod)
- VS Code: 1.110.1 (61b3d0ab13be7dda2389f1d3e60a119c7f660cc3)
- OS: win32 10.0.26100 x64
- GitHub Account: cletuschukwu-cmd

## Network

User Settings:
```json
  "http.systemCertificatesNode": true,
  "github.copilot.advanced.debug.useElectronFetcher": true,
  "github.copilot.advanced.debug.useNodeFetcher": false,
  "github.copilot.advanced.debug.useNodeFetchFetcher": true
```

Connecting to https://api.github.com:
- DNS ipv4 Lookup: 140.82.114.5 (37 ms)
- DNS ipv6 Lookup: Error (31 ms): getaddrinfo ENOTFOUND api.github.com
- Proxy URL: None (0 ms)
- Electron fetch (configured): timed out after 10 seconds
- Node.js https: Error (38 ms): Error: getaddrinfo ENOTFOUND api.github.com
	at GetAddrInfoReqWrap.onlookupall [as oncomplete] (node:dns:122:26)
- Node.js fetch: Error (7 ms): TypeError: fetch failed
	at node:internal/deps/undici/undici:14902:13
	at process.processTicksAndRejections (node:internal/process/task_queues:105:5)
	at async n._fetch (c:\Users\Administrator\.vscode\extensions\github.copilot-chat-0.38.2\dist\extension.js:5001:4900)
	at async n.fetch (c:\Users\Administrator\.vscode\extensions\github.copilot-chat-0.38.2\dist\extension.js:5001:4212)
	at async d (c:\Users\Administrator\.vscode\extensions\github.copilot-chat-0.38.2\dist\extension.js:5033:190)
	at async Jm._executeContributedCommand (file:///c:/Program%20Files/Microsoft%20VS%20Code/61b3d0ab13/resources/app/out/vs/workbench/api/node/extensionHostProcess.js:494:48675)
  Error: getaddrinfo ENOTFOUND api.github.com
  	at GetAddrInfoReqWrap.onlookupall [as oncomplete] (node:dns:122:26)

Connecting to https://api.githubcopilot.com/_ping:
- DNS ipv4 Lookup: 140.82.112.21 (31 ms)
- DNS ipv6 Lookup: Error (31 ms): getaddrinfo ENOTFOUND api.githubcopilot.com
- Proxy URL: None (1 ms)
- Electron fetch (configured): timed out after 10 seconds
- Node.js https: Error (30 ms): Error: getaddrinfo ENOTFOUND api.githubcopilot.com
	at GetAddrInfoReqWrap.onlookupall [as oncomplete] (node:dns:122:26)
- Node.js fetch: Error (8 ms): TypeError: fetch failed
	at node:internal/deps/undici/undici:14902:13
	at process.processTicksAndRejections (node:internal/process/task_queues:105:5)
	at async n._fetch (c:\Users\Administrator\.vscode\extensions\github.copilot-chat-0.38.2\dist\extension.js:5001:4900)
	at async n.fetch (c:\Users\Administrator\.vscode\extensions\github.copilot-chat-0.38.2\dist\extension.js:5001:4212)
	at async d (c:\Users\Administrator\.vscode\extensions\github.copilot-chat-0.38.2\dist\extension.js:5033:190)
	at async Jm._executeContributedCommand (file:///c:/Program%20Files/Microsoft%20VS%20Code/61b3d0ab13/resources/app/out/vs/workbench/api/node/extensionHostProcess.js:494:48675)
  Error: getaddrinfo ENOTFOUND api.githubcopilot.com
  	at GetAddrInfoReqWrap.onlookupall [as oncomplete] (node:dns:122:26)

Connecting to https://copilot-proxy.githubusercontent.com/_ping:
- DNS ipv4 Lookup: 4.249.131.160 (26 ms)
- DNS ipv6 Lookup: Error (27 ms): getaddrinfo ENOTFOUND copilot-proxy.githubusercontent.com
- Proxy URL: None (2 ms)
- Electron fetch (configured): timed out after 10 seconds
- Node.js https: Error (30 ms): Error: getaddrinfo ENOTFOUND copilot-proxy.githubusercontent.com
	at GetAddrInfoReqWrap.onlookupall [as oncomplete] (node:dns:122:26)
- Node.js fetch: Error (7 ms): TypeError: fetch failed
	at node:internal/deps/undici/undici:14902:13
	at process.processTicksAndRejections (node:internal/process/task_queues:105:5)
	at async n._fetch (c:\Users\Administrator\.vscode\extensions\github.copilot-chat-0.38.2\dist\extension.js:5001:4900)
	at async n.fetch (c:\Users\Administrator\.vscode\extensions\github.copilot-chat-0.38.2\dist\extension.js:5001:4212)
	at async d (c:\Users\Administrator\.vscode\extensions\github.copilot-chat-0.38.2\dist\extension.js:5033:190)
	at async Jm._executeContributedCommand (file:///c:/Program%20Files/Microsoft%20VS%20Code/61b3d0ab13/resources/app/out/vs/workbench/api/node/extensionHostProcess.js:494:48675)
  Error: getaddrinfo ENOTFOUND copilot-proxy.githubusercontent.com
  	at GetAddrInfoReqWrap.onlookupall [as oncomplete] (node:dns:122:26)

Connecting to https://mobile.events.data.microsoft.com: timed out after 10 seconds
Connecting to https://dc.services.visualstudio.com: timed out after 10 seconds
Connecting to https://copilot-telemetry.githubusercontent.com/_ping: Error (42 ms): Error: getaddrinfo ENOTFOUND copilot-telemetry.githubusercontent.com
	at GetAddrInfoReqWrap.onlookupall [as oncomplete] (node:dns:122:26)
Connecting to https://copilot-telemetry.githubusercontent.com/_ping: Error (5 ms): Error: getaddrinfo ENOTFOUND copilot-telemetry.githubusercontent.com
	at GetAddrInfoReqWrap.onlookupall [as oncomplete] (node:dns:122:26)
Connecting to https://default.exp-tas.com: Error (33 ms): Error: getaddrinfo ENOTFOUND default.exp-tas.com
	at GetAddrInfoReqWrap.onlookupall [as oncomplete] (node:dns:122:26)

Number of system certificates: 37

## Documentation

In corporate networks: [Troubleshooting firewall settings for GitHub Copilot](https://docs.github.com/en/copilot/troubleshooting-github-copilot/troubleshooting-firewall-settings-for-github-copilot).