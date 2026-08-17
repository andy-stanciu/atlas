import esphome.codegen as cg
import esphome.config_validation as cv
from esphome.const import CONF_ID, CONF_PORT
from esphome.components import microphone, speaker, switch

CONF_HOST = "host"
CONF_MIC = "microphone_id"
CONF_SPK = "speaker_id"
CONF_DEBUG = "debug"
CONF_RESPAKER_ID = "respeaker_id"
CONF_MUTE_SWITCH_ID = "mute_switch_id"
CONF_BEAM_OFFSET = "beam_offset"

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
        cv.Optional(CONF_RESPAKER_ID): cv.use_id(cg.Component),
        cv.Optional(CONF_MUTE_SWITCH_ID): cv.use_id(switch.Switch),
        cv.Optional(CONF_BEAM_OFFSET, default=0): cv.int_range(min=-12, max=12),
        cv.Optional(CONF_DEBUG, default=False): cv.boolean,
    }
).extend(cv.COMPONENT_SCHEMA)


async def to_code(config):
    var = cg.new_Pvariable(config[CONF_ID])
    await cg.register_component(var, config)
    cg.add(var.set_server(config[CONF_HOST], config[CONF_PORT]))
    cg.add(var.set_microphone(await cg.get_variable(config[CONF_MIC])))
    cg.add(var.set_speaker(await cg.get_variable(config[CONF_SPK])))
    cg.add(var.set_debug(config[CONF_DEBUG]))
    cg.add(var.set_beam_offset(config[CONF_BEAM_OFFSET]))
    if CONF_RESPAKER_ID in config:
        cg.add(var.set_respeaker(await cg.get_variable(config[CONF_RESPAKER_ID])))
    if CONF_MUTE_SWITCH_ID in config:
        cg.add(var.set_mute_switch(await cg.get_variable(config[CONF_MUTE_SWITCH_ID])))
