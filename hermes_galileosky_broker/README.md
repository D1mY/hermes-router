# Hermes Galileosky protocol broker
## About
Application providing:
* parsing packets of points by Galileosky protocol to list of Erlang terms
* transfering parsed lists as messages to RabbitMQ exchange `hermes.fanout` with key `hermes`
* listening configs from `hermes_galileosky_cfg` queue