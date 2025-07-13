import json
import itertools

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

def iter_colliders_parms(node):
    colliders_parm = node.parm("colliders")
    num_colliders= colliders_parm.eval()
    parm_groups = multiparm_iter(colliders_parm)

    for collider in parm_groups:
        ctype, r, g, b, xpos, ypos, resx, resy = collider
        ctype = ctype.evalAsInt()
        if ctype == 0:
            continue
        xpos = xpos.evalAsInt()
        ypos = ypos.evalAsInt()
        resx = resx.evalAsInt()
        resy = resy.evalAsInt()
        yield (ctype, xpos, ypos, resx, resy )


def reorder_callback(kwargs):
    node = kwargs["node"]
    reverse = kwargs["script_value"] == "high_to_low"
    elements = []
    for element in iter_elements_parms(node):
        elements.append(element)
    print(elements)
    node.parm("elements").set(0)
    node.parm("elements").set(len(elements))
    elements.sort(key=lambda x: x[3], reverse=reverse)
    for element, parms in zip(elements, multiparm_iter(node.parm("elements"))):
        bitmap_id, pos_x, pos_y, depth, foffset, flip = parms
        bitmap_id.set(element[0])
        pos_x.set(element[1])
        pos_y.set(element[2])
        depth.set(element[3])
        foffset.set(element[4])
        flip.set(element[5])


# {"level_name" : {
#  {"sprites" : [
#   {".total_sprites." : int},
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
#   ],
#  ]},
#  {"colliders" : [
#   {".total_colliders." : int},
#   [
#    {"collider" : {
#     {"position" : [int, int]},
#     {"resx" : int},
#     {"resy" : int},
#    }},
#    {"collider" : {
#      ...
#    }},
#   ],
#  ]},
# }}


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
        elements.append(
            {
                "animated": True if not static else False,
                "duration": duration,
                "bitmap_offset": id_offset,
            }
        )
        id_offset += 1 if static else duration

    export_elements = []
    level_name = (
        level_name if (level_name := node.parm("level_name").eval()) else "None"
    )
    total_elements = 0
    total_colliders = 0

    sprite_list = []
    collider_list = []
    level_dict = {
        ".level_name." : level_name,
        "level_data" : {
            "sprites" : [
                {".total_sprites.": total_elements},
                sprite_list,
            ],
            "colliders" : [
                {".total_colliders.": total_colliders},
                collider_list,
            ],
        }
    }
    for element_id, pos_x, pos_y, depth, foffset, flip in iter_elements_parms(node):
        if element_id < 0:
            continue
        element = elements[element_id]
        total_elements += 1
        sprite = {
            "sprite": {
                "bitmap_id": element["bitmap_offset"],
                "position": [pos_x, pos_y],
                "depth": depth,
                "animated": element["animated"],
                "duration": element["duration"],
                "frame_offset": foffset,
                "flip": flip,
            }
        }
        sprite_list.append(sprite)
    if total_elements:
        level_dict["level_data"]["sprites"][0][".total_sprites."] = total_elements
    for ctype, xpos, ypos, resx, resy  in iter_colliders_parms(node):
        total_colliders += 1
        collider = {
            "collider": {
                "position": [xpos, ypos],
                "resx": resx,
                "resy": resy,
                "ctype": ctype,
            }
        }
        collider_list.append(collider)
    if total_colliders:
        level_dict["level_data"]["colliders"][0][".total_colliders."] = total_colliders

    return level_dict


def build_colliders_geo(node):

    node = hou.pwd()
    geo = node.geometry()

    bg_geo = node.input(1).geometry()
    bg_vol = bg_geo.prims()[0]
    xres, yres, zres = bg_vol.resolution()
    max_res = max(*bg_vol.resolution())
    xratio = xres/max_res
    yratio = yres/max_res

    colliders = geo.attribValue("parms")["colliders"]

    sop_cat = hou.sopNodeTypeCategory()
    grid_verb = sop_cat.nodeVerb("grid")
    primitive_verb = sop_cat.nodeVerb("primitive")
    resample_verb = sop_cat.nodeVerb("resample")
    add_verb = sop_cat.nodeVerb("add")
    #polyextrude_verb = sop_cat.nodeVerb("polyextrude::2.0")
    font_verb = sop_cat.nodeVerb("font")
    primitive_verb.setParms({"closeu" : 5,})
    #polyextrude_verb.setParms({"dist": -0.01,})
    resample_verb.setParms({
        "edge": 1,
        "length": 0.025,
        "onlypoints" : 1,
    })
    add_verb.setParms({
        "switcher" : 1,
        "add": 1,
    })
    for collider in colliders:
        if collider["collider_type#"] == 0:
            continue

        new_geo = hou.Geometry()
        size_x = collider["collider_size#"][0]/max_res*2
        size_y = collider["collider_size#"][1]/max_res*2
        pos_x = (collider["collider_pos#"][0]/max_res*2)+size_x/2 - xratio
        pos_y = 1*yratio - (collider["collider_pos#"][1]/max_res*2)-size_y/2
        grid_verb.setParms({
            "size": hou.Vector2(size_x, size_y),
            "rows": 2,
            "cols": 2,
            "orient": 0,
            "t": hou.Vector3(pos_x, pos_y, 0.0),
        })
        grid_verb.execute(new_geo, [])
        primitive_verb.execute(new_geo, [new_geo,])
        Cd_atr = new_geo.addAttrib(hou.attribType.Prim, "Cd", [1.0, 1.0, 1.0], create_local_variable=False)
        nprims = len(new_geo.iterPrims())
        flood_colors = list(itertools.chain(list(collider["collider_color#"])*nprims))
        new_geo.setPrimFloatAttribValues("Cd", flood_colors)
        geo.merge(new_geo)


def export_callback(node):
    path = node.parm("export_path").eval()
    if not path:
        return
    level_export = build_level(node)
    with open(path, "w") as json_f:
        json.dump(level_export, json_f, indent=1)
