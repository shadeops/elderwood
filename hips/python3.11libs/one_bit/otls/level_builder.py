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
#     {"flip" : bool},
#     {"frame_offset" : int},
#     {"animated" : bool},
#     {"duration" : int},
#    }},
#    {"sprite" : {
#      ...
#    }},
#   ]
# ]}


def build_level(node):

    # TODO: Possibly replace this with the info from the detail (ie: library_to_detail)

    # The naming is a bit convoluted. It Houdini we refer to the "bitmap_id" as a reference
    # to which 'element' we are using. Where the element might be animated and have multiple
    # frames. On the Playdate side we just have an array of "bitmap_id"s which is a flatten
    # list of all the bitmaps. We use the id_offset to map between Houdini's bitmap_ids (element_ids)
    # to the Playdate's bitmap_ids
    # TODO: Renaming all usage of bitmap_id with element_id in Houdini.
    elements = []
    id_offset = 0
    for pt in node.node("bitmap_library").geometry().points():
        static = pt.attribValue("static")
        start_frame = pt.attribValue("start_frame")
        end_frame = pt.attribValue("end_frame")
        duration = 1 if static else end_frame - start_frame + 1
        elements.append({
            "animated" : True if not static else False,
            "duration" : duration,
            "bitmap_offset" : id_offset,
        })
        id_offset += 1 if static else duration

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
    for element_id, pos_x, pos_y, depth, foffset, flip in iter_elements_parms(node):
        element = elements[element_id]
        sprite = {
            "sprite": {
                "bitmap_id": element["bitmap_offset"],
                "position": [pos_x, pos_y],
                "depth": depth,
                "animated" : element["animated"],
                "duration" : element["duration"],
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
