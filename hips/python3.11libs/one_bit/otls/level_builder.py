import json

import hou

ignored_parm_templates = (
    hou.ButtonParmTemplate,
    hou.FolderParmTemplate,
    hou.FolderSetParmTemplate,
    hou.LabelParmTemplate,
    hou.SeparatorParmTemplate,
)


def multiparm_iter(parm):
    parms = parm.multiParmInstances()
    num = parm.multiParmInstancesPerItem()
    for i in range(0, len(parms), num):
        yield [
            p
            for p in parms[i : i + num]
            if not isinstance(p.parmTemplate(), ignored_parm_templates)
        ]


def iter_elements_parms(node):
    elements_parm = node.parm("elements")
    num_elements = elements_parm.eval()
    parm_groups = multiparm_iter(elements_parm)

    for element in parm_groups:
        bitmap_id, pos_x, pos_y, depth, foffset, flip = element
        bitmap_id = bitmap_id.evalAsInt()
        pos_x = pos_x.evalAsInt()
        pos_y = pos_y.evalAsInt()
        depth = depth.evalAsInt()
        foffset = foffset.evalAsInt()
        flip = bool(flip.eval())
        yield (bitmap_id, pos_x, pos_y, depth, foffset, flip)


# {"level_name" : [
#   {"total_sprites" : int},
#   [
#    {"sprite" : {
#     {"bitmap_id" : int},
#     {"position" : [int, int]},
#     {"depth" : int},
#     {"frame_offset" : int},
#     {"flip" : bool},
#    }},
#    {"sprite" : {
#      ...
#    }},
#   ]
# ]}


def build_level(node):
    export_elements = []
    level_name = (
        level_name if (level_name := node.parm("level_name").eval()) else "None"
    )
    total_elements = node.parm("elements").evalAsInt()
    sprite_list = []
    level_dict = {
        level_name: [
            {"total_sprites": total_elements},
            sprite_list,
        ]
    }
    for bitmap_id, pos_x, pos_y, depth, foffset, flip in iter_elements_parms(node):

        sprite = {
            "sprite": {
                "bitmap_id": bitmap_id,
                "position": [pos_x, pos_y],
                "depth": depth,
                "frame_offset": foffset,
                "flip": flip,
            }
        }
        sprite_list.append(sprite)
    return level_dict


def export_callback(node):
    path = node.parm("export_path").eval()
    if not path:
        return
    level_export = build_level(node)
    with open(path, "w") as json_f:
        json.dump(level_export, json_f, indent=1)
