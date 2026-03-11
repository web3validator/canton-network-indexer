import { FastifyInstance } from "fastify";
import { getNodeStatus, validatorNodeEnabled } from "../../collectors/validator-node.js";

export async function registerValidatorNodeRoutes(server: FastifyInstance): Promise<void> {
  server.get(
    "/validator/node-status",
    {
      schema: {
        tags: ["validators"],
        summary: "Local validator node ingestion lag (requires VALIDATOR_DB_URL)",
        response: {
          200: {
            type: "object",
            properties: {
              enabled: { type: "boolean" },
              lag_seconds: { type: "number", nullable: true },
              last_ingested_at: { type: "string", nullable: true },
              is_healthy: { type: "boolean", nullable: true },
              validator_name: { type: "string", nullable: true },
              validator_party: { type: "string", nullable: true },
            },
          },
        },
      },
    },
    async (_req, reply) => {
      if (!validatorNodeEnabled) {
        return reply.send({
          enabled: false,
          lag_seconds: null,
          last_ingested_at: null,
          is_healthy: null,
          validator_name: null,
          validator_party: null,
        });
      }

      const status = await getNodeStatus();
      if (!status) {
        return reply.send({
          enabled: true,
          lag_seconds: null,
          last_ingested_at: null,
          is_healthy: null,
          validator_name: null,
          validator_party: null,
        });
      }

      return reply.send({ enabled: true, ...status });
    },
  );
}
