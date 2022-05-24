# Hermes Galileosky protocol broker
## About
Provides:

* parsing packets of Galileosky protocol points to list of Erlang terms
* publishing parsed lists as messages to RabbitMQ exchange `hermes.fanout` with key `hermes`
* listening config messages from `hermes_galileosky_broker_cfg` queue
