import esphome.codegen as cg
import esphome.config_validation as cv
from esphome.const import CONF_ID, CONF_PORT
from esphome.components import microphone

CONF_HOST = "host"
CONF_MIC = "microphone_id"
CONF_RESPAKER_ID = "respeaker_id"
CONF_LOG_STATS = "log_stats"

DEPENDENCIES = ["microphone"]

ns = cg.esphome_ns.namespace("atlas_capture")
AtlasCapture = ns.class_("AtlasCapture", cg.Component)

CONFIG_SCHEMA = cv.Schema(
    {
        cv.GenerateID(): cv.declare_id(AtlasCapture),
        cv.Required(CONF_HOST): cv.string_strict,
        cv.Required(CONF_PORT): cv.port,
        cv.Required(CONF_MIC): cv.use_id(microphone.Microphone),
        cv.Required(CONF_RESPAKER_ID): cv.use_id(cg.Component),
        cv.Optional(CONF_LOG_STATS, default=False): cv.boolean,
    }
).extend(cv.COMPONENT_SCHEMA)


async def to_code(config):
    var = cg.new_Pvariable(config[CONF_ID])
    await cg.register_component(var, config)
    cg.add(var.set_server(config[CONF_HOST], config[CONF_PORT]))
    cg.add(var.set_microphone(await cg.get_variable(config[CONF_MIC])))
    cg.add(var.set_respeaker(await cg.get_variable(config[CONF_RESPAKER_ID])))
    cg.add(var.set_log_stats(config[CONF_LOG_STATS]))
