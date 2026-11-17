import {
  coreServices,
  createBackendModule,
} from '@backstage/backend-plugin-api';
import { policyExtensionPoint } from '@backstage/plugin-permission-node/alpha';
import type {
  PermissionPolicy,
  PolicyQuery,
  PolicyQueryUser,
} from '@backstage/plugin-permission-node';
import {
  AuthorizeResult,
  type PolicyDecision,
} from '@backstage/plugin-permission-common';

// Politique pilote : DENY par defaut. Les principals de type service (token externalAccess statique
// des agents) ne passent PAS par cette politique : leurs decisions viennent des accessRestrictions
// du token (ServerPermissionClient.#servicePrincipalDecision). Voir BACKSTAGE.md, section permissions.
const USER_ALLOW_NAMES = new Set([
  'catalog.entity.read',
  'catalog.location.read',
  'scaffolder.template.parameter.read',
  'scaffolder.template.step.read',
  'scaffolder.task.read',
  'scaffolder.template.dry-run',
  'scaffolder.task.create',
  'scaffolder.action.execute',
]);

class PilotePolicy implements PermissionPolicy {
  constructor(private readonly logger: { info: (m: string) => void }) {}

  async handle(
    request: PolicyQuery,
    user?: PolicyQueryUser,
  ): Promise<PolicyDecision> {
    const name = request.permission.name;
    const who = user?.info?.userEntityRef ?? 'anonymous';
    let result: AuthorizeResult.ALLOW | AuthorizeResult.DENY =
      AuthorizeResult.DENY;
    if (user && who.startsWith('user:') && USER_ALLOW_NAMES.has(name)) {
      result = AuthorizeResult.ALLOW;
    }
    this.logger.info(`pilote-policy ${who} ${name} -> ${result}`);
    return { result };
  }
}

export default createBackendModule({
  pluginId: 'permission',
  moduleId: 'pilote-policy',
  register(reg) {
    reg.registerInit({
      deps: {
        policy: policyExtensionPoint,
        logger: coreServices.logger,
      },
      async init({ policy, logger }) {
        policy.setPolicy(new PilotePolicy(logger));
      },
    });
  },
});
