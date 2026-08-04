# Multiple SQL clients on one Windows device

Use one isolated portable agent installation for each SQL Server/database endpoint. This preserves independent identities, Change Tracking cursors, retries, logs, startup shortcuts, and updates. One agent process multiplexing several databases is intentionally not used because a shared state machine would couple failures and recovery.

The original installation remains the default client. In the client, open **Settings**, choose **Add separate SQL client**, enter the second endpoint, and choose **Create client**. The new client starts in the background.

The packaged PowerShell command provides the same operation for unattended setup:

```powershell
.\create_client_instance.ps1 -InstanceId sql8 -DisplayName "Alshallan2 SQL8" -Server 'DESKTOP-6MQFNA3\SQL8' -Database 'AmnDb048'
```

For the two endpoints shown on the Alshallan2 device, configure separate instances for:

- `DESKTOP-6MQFNA3\SQL8` / `AmnDb048`
- `DESKTOP-ALDNHIH\SQLEXPRESS` / `AmnDb048`

The creator copies the current portable client into `%LOCALAPPDATA%\Microsoft-SQL-Server-Sync\instances\<id>`, copies remembered authentication into an isolated state file, saves the requested SQL endpoint, and starts its supervisor hidden. Windows does not ask the user to create another control-plane account. The server exposes the instance as `<account>--<id>` and restricts that alias to the authenticated account.

The script refuses invalid IDs and existing target folders. Use `-NoStart` only for isolated testing. Creating an instance does not start a synchronization job; start or schedule sync from the web control plane after both clients are online and their table policies are verified.
