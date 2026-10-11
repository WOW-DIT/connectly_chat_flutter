## 0.1.0

Initial release.

* Text chat over Socket.IO, matching the Connectly `chatting-ws-server` protocol.
* Guest sessions (persisted `visitor_id`) and identified sessions (`identifyToken`).
* Typing indicator (both directions), "talk to a human" handoff flow.
* File attachments and voice notes via `connectly.chatting.api.send_attachment`.
* Configurable theme (`ConnectlyChatTheme`) and behavior (`ConnectlyChatOptions`).
* Compile-time configuration via `ConnectlyChatConfig.fromEnvironment()`.
