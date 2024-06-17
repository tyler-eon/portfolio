import Config

config :logger,
  backends: [LoggerJSON],
  level: :debug

config :logger_json, :backend,
  metadata: :all,
  formatter: LoggerJSON.Formatters.BasicLogger

# The maximum cost in seconds for various job types.
config :credits, :caps, [
  {60,
   [
     "job_1",
     "job_2",
     "ex_5"
   ]},
  {80,
   [
     "job_4",
     "ex_1"
   ]},
  {120,
   [
     "job_3"
   ]}
]

config :credits, :broadway,
  producer: [
    concurrency: 1
  ],
  processors: [
    default: [
      concurrency: 10,
      max_demand: 100
    ]
  ]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
