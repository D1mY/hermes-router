PROJECT = hermes_galileosky
PROJECT_DESCRIPTION = Hermes Galileosky server
PROJECT_MOD = hermes_galileosky

DEPS = rabbit_common rabbit amqp_client
RABBITMQ_CLIENT_PATCH = 1

DEP_EARLY_PLUGINS = rabbit_common/mk/rabbitmq-early-plugin.mk
DEP_PLUGINS = rabbit_common/mk/rabbitmq-plugin.mk

# FIXME: Use erlang.mk patched for RabbitMQ, while waiting for PRs to be
# reviewed and merged.

ERLANG_MK_REPO = https://github.com/rabbitmq/erlang.mk.git
ERLANG_MK_COMMIT = rabbitmq-tmp

include rabbitmq-components.mk
include erlang.mk
