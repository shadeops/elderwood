import hou
import json

# TODO the naming is all over the map (hurrr) and should stick
# to one convention

dir_id_to_name = ["west_of","south_of","east_of","north_of"]

class ConnectsTo:
    def __init__(self):
        self.east = None
        self.north = None
        self.west = None
        self.south = None
    def as_dict(self):
        return {
            "east" : self.east,
            "north" : self.north,
            "west" : self.west,
            "south" : self.south,
        }
    def a_to_b_direction(self, direction, where):
        if direction == 0: # "west_of"
            if self.east is not None:
                raise ValueError("east already set")
            self.east = where
        elif direction == 2: # "east_of":
            if self.west is not None:
                raise ValueError("west already set")
            self.west = where
        elif direction == 3: #"above"
            if self.south is not None:
                raise ValueError("south already set")
            self.south = where
        elif direction == 1: #"south_of"
            if self.north is not None:
                raise ValueError("north already set")
            self.north = where

    def b_to_a_direction(self, direction, where):
        if direction == 0: # "west_of"
            if self.west is not None:
                raise ValueError("west already set")
            self.west = where
        elif direction == 2: # "east_of"
            if self.east is not None:
                raise ValueError("east already set")
            self.east = where
        elif direction == 3: # "above"
            if self.north is not None:
                raise ValueError("north already set")
            self.north = where
        elif direction == 1: # "south_of"
            if self.south is not None:
                raise ValueError("south already set")
            self.south = where

    def __str__(self):
        return (f"{self.east}, "
                f"{self.north}, "
                f"{self.west}, "
                f"{self.south}"
            )

    def __repr__(self):
        return self.__str__()

# {"map" : {
#    ".collision_pad.": int,
#    ".starting_level.": int,
#    ".player_pos_x.": int,
#    ".player_pos_y.": int,
#    ".levels." : [
#       {".number_levels." : int},
#       {"level" : {
#           "name" : str,
#           "id" : int,
#           "east" : int | null,
#           "west" : int | null,
#           "north" : int | null,
#           "south" : int | null,
#       }},
#   ]},
# }


def export_map(node):

    level_to_id = {}
    level_names = []
    for i,n in enumerate(node.inputs()):
        level_to_id[n.name()] = i
        level_names.append(n.name())

    # TODO rename this part from levels to connections
    levels = []
    export_map = {"map" : {
        ".collision_pad." : node.parm("collision_padding").evalAsInt(),
        ".starting_level." : node.parm("starting_level").evalAsInt(),
        ".player_pos_x." : node.parm("player_start_posx").evalAsInt(),
        ".player_pos_y." : node.parm("player_start_posy").evalAsInt(),
        "levels" : levels,
    }}

    edges = node.parm("levels").evalAsInt()
    spawned_levels = set()
    connections = {}
    for edge in range(1,edges+1):
        a = node.parm(f"level_a{edge}").evalAsString()
        b = node.parm(f"level_b{edge}").evalAsString()
        dir_id = node.parm(f"placement{edge}").evalAsInt()

        spawned_levels.add(a)
        spawned_levels.add(b)
        if a not in connections:
            connections[a] = ConnectsTo()
        if b not in connections:
            connections[b] = ConnectsTo()
        connections[a].a_to_b_direction(dir_id, level_to_id[b])
        connections[b].b_to_a_direction(dir_id, level_to_id[a])

    levels.append({".total_levels." : len(spawned_levels)})
    # TODO For now, we'll just create levels even if they don't
    # have connections. Partially for debugging and to avoid
    # having to rebalance offset ids. But this show be fixed
    for level_id, level_name in enumerate(level_names):
        level = {"level" : {
                    "name" : level_name,
                }}
        level["level"].update(connections.get(level_name, ConnectsTo()).as_dict())
        levels.append(level)
    return export_map

def layout_map(node):
    node = hou.pwd()
    hda = node.parent()
    geo = node.geometry()

    geos = {}
    level_to_id = {}
    level_ids = []
    for i,n in enumerate(hda.inputs()):
        geos[n.name()] = n.geometry().freeze()
        level_to_id[n.name()] = i
        level_ids.append(n)

    level_connections = hda.parm("levels").evalAsInt()

    skel_geo = hou.Geometry()

    level_pts = {}
    name_atr = skel_geo.addAttrib(hou.attribType.Point, "name", "", create_local_variable=False)
    dir_atr = skel_geo.addAttrib(hou.attribType.Prim, "dir", "", create_local_variable=False)
    level_id_atr = skel_geo.addAttrib(hou.attribType.Point, "level_id", -1, create_local_variable=False)

    ## Build Edges and Points

    edges = []
    for edge_num in range(level_connections):
        a = hda.parm(f"level_a{edge_num+1}").evalAsString()
        b = hda.parm(f"level_b{edge_num+1}").evalAsString()
        dir_id = hda.parm(f"placement{edge_num+1}").evalAsInt()
        direction = dir_id_to_name[dir_id]

        # reorder so preferring left of and south_of
        if direction in ("south_of", "east_of"):
            a,b = b,a
            direction = "north_of" if direction == "south_of" else "west_of"
        edges.append([a, b, direction])

        pt_a = level_pts.get(a)
        if pt_a is None:
            pt_a = skel_geo.createPoint()
            pt_a.setAttribValue(name_atr, a)
            pt_a.setAttribValue(level_id_atr, level_to_id[a])
            level_pts[a] = pt_a

        pt_b = level_pts.get(b)
        if pt_b is None:
            pt_b = skel_geo.createPoint()
            pt_b.setAttribValue(name_atr, b)
            pt_a.setAttribValue(level_id_atr, level_to_id[b])
            level_pts[b] = pt_b

        poly = skel_geo.createPolygon(is_closed=False)
        poly.setAttribValue(dir_atr, direction)
        poly.addVertex(pt_a)
        poly.addVertex(pt_b)

    space_x = 2 + hda.parm("padding").eval()
    space_y = 240/400*space_x

    check_queue = [[edges[0][0], hou.Vector3(0,0,0)],]
    checked = set()

    # Layout Points

    emergency_escape = 0
    while check_queue and emergency_escape < 1000:
        emergency_escape+=1

        check, pos = check_queue.pop()
        checked.add(check)
        for edge in edges:
            a,b,direction = edge
            if check == a:
                if direction == "west_of":
                    d = hou.Vector3(space_x, 0, 0)
                else:
                    d = hou.Vector3(0, -space_y, 0)
                to_check = b
            elif check == b:
                if direction == "west_of":
                    d = hou.Vector3(-space_x, 0, 0)
                else:
                    d = hou.Vector3(0, space_y, 0)
                to_check = a
            else:
                continue

            new_pos = pos + d
            level_pts[to_check].setPosition(new_pos)
            if to_check not in checked:
                check_queue.append([to_check, new_pos])

    ## Copy Levels to Points

    for pt in skel_geo.iterPoints():
        pt_name = pt.attribValue(name_atr)
        input_geo = geos[pt_name]
        xform = hou.hmath.buildTranslate(pt.position())
        input_geo.transform(xform)
        geo.merge(input_geo)

    if hda.parm("show_skel").eval():
        geo.merge(skel_geo)

    if hda.parm("show_player").eval():
        # TODO This makes a lot of assumptions about input volumes being their
        # default 2 in the x in terms of size
        start_pt = hda.parm("starting_level").evalAsString()
        start_pt = level_pts[start_pt]
        start_pos = start_pt.position()
        start_x = hda.parm("player_start_posx").evalAsInt()
        start_y = hda.parm("player_start_posy").evalAsInt()
        start_x = start_x/400*2 - 1
        start_y = 240/400 - start_y/400*2

        start_x += start_pos[0]
        start_y += start_pos[1]

        # TODO, we can't create hou.Quadrics from a hou.Geometry()?
        sphere_verb = hou.sopNodeTypeCategory().nodeVerb("sphere")
        sphere_verb.setParms({
            "type": 0,
            "rad": [0.03, 0.03, 0.03],
            "t" : [start_x, start_y, 0]
        })
        sphere_geo = hou.Geometry()
        sphere_verb.execute(sphere_geo, [])
        cd_atr = sphere_geo.addAttrib(hou.attribType.Prim, "Cd", [1.,1.,1.], create_local_variable=False)
        sphere_geo.prims()[0].setAttribValue(cd_atr, [0.,0.,1.])
        geo.merge(sphere_geo)

    if len(checked) < len(level_pts):
        unconnected = set(level_pts) - checked
        raise hou.NodeWarning(f"{', '.join(unconnected)} not connected")


def export_callback(kwargs):
    node = kwargs["node"]
    path = node.parm("export_path").eval()
    if not path:
        return
    map_export = export_map(node)
    with open(path, "w") as json_f:
        json.dump(map_export, json_f, indent=1)

