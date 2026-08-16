import esphome.codegen as cg
import esphome.config_validation as cv
from esphome.const import CONF_ID, CONF_PORT
from esphome.components import microphone, speaker

CONF_HOST = "host"
CONF_MIC = "microphone_id"
CONF_SPK = "speaker_id"

DEPENDENCIES = ["microphone", "speaker"]

ns = cg.esphome_ns.namespace("atlas_link")
AtlasLink = ns.class_("AtlasLink", cg.Component)

CONFIG_SCHEMA = cv.Schema(
    {
        cv.GenerateID(): cv.declare_id(AtlasLink),
        cv.Required(CONF_HOST): cv.string_strict,
        cv.Required(CONF_PORT): cv.port,
        cv.Required(CONF_MIC): cv.use_id(microphone.Microphone),
        cv.Required(CONF_SPK): cv.use_id(speaker.Speaker),
    }
).extend(cv.COMPONENT_SCHEMA)


async def to_code(config):
    var = cg.new_Pvariable(config[CONF_ID])
    await cg.register_component(var, config)
    cg.add(var.set_server(config[CONF_HOST], config[CONF_PORT]))
    cg.add(var.set_microphone(await cg.get_variable(config[CONF_MIC])))
    cg.add(var.set_speaker(await cg.get_variable(config[CONF_SPK])))
