import { createMcpExpressApp } from "@modelcontextprotocol/sdk/server/express.js";
import { requireBearerAuth } from "@modelcontextprotocol/sdk/server/auth/middleware/bearerAuth.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import helmet from "helmet";
import { APP_DISPLAY_NAME } from "./app.js";
import { createOAuthRouter } from "./auth/oauth-routes.js";
import { TokenService } from "./auth/tokens.js";
import { McpAccessTokenVerifier } from "./auth/verifier.js";
import { loadConfig } from "./config.js";
import { log } from "./logging.js";
import { createMcpServer } from "./mcp/server.js";
import { createRuntime } from "./runtime.js";
import { createMicrosoftConsentRouter } from "./microsoft/consent-routes.js";
import { createGoogleCollectorConsentRouter } from "./google/consent-routes.js";

const config = loadConfig();
const services = createRuntime(config);
try {
  await services.loadGoogleTokens();
} catch (error) {
  // Keep the consent endpoints available when an encryption-key rotation makes
  // the previous token envelope unreadable. The collector remains fail-closed
  // because its CLI still requires every configured token to load successfully.
  log.error({
    event: "google_token_state_unavailable_at_startup",
    code: error instanceof Error && "code" in error ? String(error.code) : "unknown_error",
  });
}

const tokens = new TokenService(config);
const verifier = new McpAccessTokenVerifier(config, tokens);
const app = createMcpExpressApp({ host: "0.0.0.0" });
app.set("trust proxy", 1);
app.use(helmet({ contentSecurityPolicy: false }));
app.use((req, res, next) => {
  res.on("finish", () => {
    log.info({ event: "http_request", method: req.method, path: req.path, status: res.statusCode });
  });
  next();
});
app.use(createMicrosoftConsentRouter(config, services.runtimeState, services.microsoftTokenStore));
app.use(createGoogleCollectorConsentRouter(config, services.runtimeState, services.googleTokenStore, services));
app.use(createOAuthRouter(config, tokens));

app.get("/", (_req, res) => {
  res.json({
    name: APP_DISPLAY_NAME,
    mode: "read-only",
    mcp_endpoint: config.mcpResourceUrl,
    channels: config.channels.map(({ key, name, youtubeChannelId }) => ({ key, name, youtube_channel_id: youtubeChannelId })),
  });
});
app.get("/health", (_req, res) => res.json({ status: "ok" }));

const protectedResourceMetadataUrl = `${config.publicBaseUrl}/.well-known/oauth-protected-resource`;
const authMiddleware = requireBearerAuth({
  verifier,
  requiredScopes: ["youtube.analytics.read"],
  resourceMetadataUrl: protectedResourceMetadataUrl,
});

app.post("/mcp", authMiddleware, async (req, res) => {
  const server = createMcpServer(config, services);
  const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined });
  try {
    await server.connect(transport);
    await transport.handleRequest(req, res, req.body);
  } catch {
    log.error({ event: "mcp_request_failed", code: "internal_error" });
    if (!res.headersSent) {
      res.status(500).json({
        jsonrpc: "2.0",
        error: { code: -32603, message: "Internal server error" },
        id: null,
      });
    }
  } finally {
    await transport.close().catch(() => undefined);
    await server.close().catch(() => undefined);
  }
});

app.get("/mcp", authMiddleware, (_req, res) => {
  res.status(405).json({
    jsonrpc: "2.0",
    error: { code: -32000, message: "Method not allowed" },
    id: null,
  });
});
app.delete("/mcp", authMiddleware, (_req, res) => {
  res.status(405).json({
    jsonrpc: "2.0",
    error: { code: -32000, message: "Method not allowed" },
    id: null,
  });
});

// This is deliberately outside every MCP tool. If YT_REACH_JOB_ID is absent,
// startup first reuses an existing matching job and creates one only if none exists.
for (const channel of services.channels.values()) {
  void channel.reporting.initialize().catch(() => {
    log.error({
      event: "reach_job_initialization_failed",
      channel: channel.channel.key,
      code: "youtube_reporting_error",
    });
  });
}

const httpServer = app.listen(config.port, "0.0.0.0", () => {
  log.info({ event: "server_started" });
});

let shuttingDown = false;
function shutdown(): void {
  if (shuttingDown) return;
  shuttingDown = true;
  httpServer.close(() => process.exit(0));
}

process.once("SIGTERM", shutdown);
process.once("SIGINT", shutdown);
