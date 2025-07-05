"""
State:          Level Builder
State type:     level_builder
Description:    Level builder
Author:         shadeops
Date Created:   June 30, 2025 - 18:27:44
"""

import hou


class Border:
    none = "none"
    grid = "grid"
    outline = "outline"

class LBState(object):

    NODE_HDAPARMS = "hda_parms"
    NODE_MASK = "mask"
    NODE_BG_IMG = "bg_img"
    NODE_BITMAP_LIB = "bitmap_library"
    NODE_COLLIDER = "collision_geo"

    PARM_ELEMENTS = "elements"

    PARM_BITMAPID = "bitmap_id"
    PARM_DEPTH= "depth"
    PARM_POSITION = "position"
    PARM_OFFSET = "frame_offset"


    def __init__(self, state_name, scene_viewer):
        self.state_name = state_name
        self.scene_viewer = scene_viewer
        self.reset_state()

    def reset_state(self):
        self.node = None
        self.elements_parm = None
        self.current_parm_idx = 0
        self.library_size = 0
        self.bg_res = [0, 0]
        self.bitmap_names = []
        self.bitmap_res = []
        self.hit_P = hou.Vector3()

        self.border_geo = None
        self.outline_geos = []
        self.border_mode = Border.outline

        self.outline = hou.SimpleDrawable(
            self.scene_viewer, hou.Geometry(), "bitmap_border"
        )

    # TODO add flip X

    def set_border_geo(self, pos):
        if self.current_id < 0 or self.border_mode == Border.none:
            return
        base_geo = (
            self.border_geo
            if self.border_mode == Border.grid
            else self.outline_geos[self.current_id]
        )
        geo = hou.Geometry()
        geo.merge(base_geo)
        scale = hou.hmath.buildScale(
            self.bitmap_res[self.current_id][0] / self.bg_res[0],
            self.bitmap_res[self.current_id][1] / self.bg_res[1],
            1,
        )
        trans = hou.hmath.buildTranslate(*pos)
        xform = scale * trans
        geo.transform(xform)
        self.outline.setGeometry(geo)

    def find_top_index(self, pixel_coord, sample_mask=False):
        node = self.node
        hda_parms = node.node(LBState.NODE_HDAPARMS).geometry().attribValue("parms")
        elements = list(hda_parms[LBState.PARM_ELEMENTS])
        for i, element in enumerate(elements):
            element["index"] = i + 1

        elements.sort(reverse=True, key=lambda k: (k["depth#"], k["index"]))

        mask_prims = node.node("mask").geometry().prims() if sample_mask else None

        for element in elements:
            x, y = element["position#"]
            id = element["bitmap_id#"]
            if id < 0:
                continue
            resx, resy = self.bitmap_res[id]
            vx = int(pixel_coord[0] - x)
            vy = int(pixel_coord[1] - y)
            vy = resy - vy
            if vx >= 0 and vx < resx and vy >= 0 and vy < resy:
                if sample_mask:
                    if mask_prims[id].voxel((vx, vy, 0)):
                        return element["index"]
                else:
                    return element["index"]

        return None

    def bitmap_values(self, index=None):
        node = self.node
        idx = self.current_parm_idx if index is None else index
        bitmap_id = node.parm(f"bitmap_id{idx}").evalAsInt()
        depth = node.parm(f"depth{idx}").evalAsInt()
        pos = node.parmTuple(f"position{idx}").eval()
        offset = node.parmTuple(f"frame_offset{idx}").eval()
        return (bitmap_id, pos, depth, offset)

    def get_indexed_parm(self, name, idx=None):
        idx = self.current_parm_idx if idx is None else idx
        parm = self.node.parm(f"{name}{idx}")
        if parm is None:
            raise ValueError(f"'elements' multiparm does not have idx ({idx})")
        return parm

    def add_bitmap(self):
        node = self.node
        # Fetch current values, and copy them into the new parm, but increment depth
        if self.current_parm_idx:
            bitmap_id, pos, depth, offset = self.bitmap_values()
        else:
            bitmap_id = 0
            pos = (0, 0)
            depth = -1
            offset = 0

        bitmap_id = max(bitmap_id, 0)

        depth += 1

        with hou.undos.disabler():
            self.current_parm_idx = self.elements_parm.evalAsInt() + 1
            self.elements_parm.set(self.current_parm_idx)
            node.parm(f"bitmap_id{self.current_parm_idx}").set(bitmap_id)
            node.parm(f"depth{self.current_parm_idx}").set(depth)
            node.parmTuple(f"position{self.current_parm_idx}").set(pos)

        return bitmap_id, pos, depth, offset

    def init_outline_geos(self):
        bg_prim = self.node.node(LBState.NODE_BG_IMG).geometry().prims()[0]
        bg_xform = hou.Matrix4(bg_prim.transform())
        bg_trans = hou.hmath.buildTranslate(*bg_prim.points()[0].position())
        bg_xform = bg_xform * bg_trans

        grid_op = hou.sopNodeTypeCategory().nodeVerb("grid")
        trace_op = hou.sopNodeTypeCategory().nodeVerb("trace")

        border_geo = hou.Geometry()
        grid_op.setParms({"size": hou.Vector2(2, 2), "rows": 2, "cols": 2, "orient": 0})
        grid_op.execute(border_geo, [])
        border_geo.transform(bg_xform)
        self.border_geo = border_geo

        outline_geos = []
        mask_geo = self.node.node("mask").geometry()
        for i, mask in enumerate(mask_geo.iterPrims()):
            geo = hou.Geometry()
            trace_op.setParms({"tracelayer": str(i)})
            trace_op.execute(geo, [mask_geo])
            geo.transform(bg_xform)
            outline_geos.append(geo)
        self.outline_geos = outline_geos

    def onEnter(self, kwargs):

        node = kwargs["node"]
        self.node = node

        self.elements_parm = node.parm(LBState.PARM_ELEMENTS)

        bg_geo = node.node(LBState.NODE_BG_IMG).geometry()
        self.bg_res = bg_geo.iterPrims()[0].resolution()

        geo = node.node(LBState.NODE_BITMAP_LIB).geometry()
        lr = geo.pointIntAttribValues("res")
        self.bitmap_res = list(zip(lr[::2], lr[1::2]))
        self.library_size = len(geo.iterPoints())
        self.bitmap_names = geo.pointStringAttribValues("bitmap")

        self.current_parm_idx = self.elements_parm.evalAsInt()
        self.current_id, pos, depth, offset = self.add_bitmap()

        hud_template = {
            "title": "Level Builder",
            "desc": "Place Bitmaps",
            "rows": [
                {
                    "type": "plain",
                    "label": "Current Item",
                    "value": self.current_id,
                    "id": "bitmap_id_label",
                },
                {
                    "type": "choicegraph",
                    "count": self.library_size,
                    "value": 0,
                    "id": "bitmap_id_choice",
                },
                {
                    "type": "plain",
                    "label": "Bitmap Name",
                    "value": self.bitmap_names[self.current_id],
                    "id": "bitmap_name_id",
                },
                {
                    "type": "plain",
                    "label": "Bitmap Res",
                    "value": self.bitmap_res[self.current_id],
                    "id": "bitmap_res_id",
                },
                {
                    "type": "plain",
                    "label": "Bitmap Depth",
                    "value": depth,
                    "id": "bitmap_depth_id",
                },
                {"type": "divider", "label": "Keys"},
                {"type": "plain", "label": "Choose Bitmap", "key": "mousewheel"},
                {"type": "plain", "label": "Modify Depth", "key": "Ctrl mousewheel"},
            ],
        }
        self.scene_viewer.hudInfo(
            hud_template=hud_template, show=True, panel=hou.hudPanel.ToolInfo
        )

        self.init_outline_geos()

        self.outline.enable(True)
        self.outline.show(True)
        self.outline.setIsControl(True)
        self.outline.setXray(True)
        self.outline.setDrawOutline(True)
        self.outline.setOutlineOnly(True)
        self.outline.setOutlineColor(hou.Color((1, 1, 0)))

    def onExit(self, kwargs):
        # annoyingly this method counts from 0
        self.elements_parm.removeMultiParmInstance(self.current_parm_idx - 1)

    def onMouseWheelEvent(self, kwargs):
        device = kwargs["ui_event"].device()
        node = self.node

        idx = self.current_parm_idx
        scroll = device.mouseWheel()

        if device.isCtrlKey():
            depth_parm = node.parm(f"depth{idx}")
            depth = depth_parm.evalAsInt()
            depth = depth - int(scroll)
            with hou.undos.disabler():
                depth_parm.set(depth)
            updates = {"bitmap_depth_id": depth}
            self.scene_viewer.hudInfo(hud_values=updates)
            return True

        current_bitmap_parm = node.parm(f"bitmap_id{idx}")
        self.current_id = current_bitmap_parm.evalAsInt()
        old_res = self.bitmap_res[self.current_id]
        old_pos = node.parmTuple(f"position{idx}").eval()

        self.current_id = (self.current_id + int(scroll)) % self.library_size

        # Pos coordinates are stored in the upper left, so we need to convert
        # from the old bitmap pos to new so the new bitmap stays centered to
        # them mouse.
        new_res = self.bitmap_res[self.current_id]
        new_pos = list(old_pos)

        new_pos[0] += (old_res[0] - new_res[0]) // 2
        new_pos[1] += (old_res[1] - new_res[1]) // 2

        with hou.undos.disabler():
            current_bitmap_parm.set(self.current_id)
            node.parmTuple(f"position{idx}").set(new_pos)

        self.set_border_geo(self.hit_P)

        updates = {
            "bitmap_id_label": self.current_id,
            "bitmap_id_choice": self.current_id,
            "bitmap_name_id": self.bitmap_names[self.current_id],
            "bitmap_res_id": new_res,
        }

        self.scene_viewer.hudInfo(hud_values=updates)
        return True

    def onMouseEvent(self, kwargs):
        ui_event = kwargs["ui_event"]
        reason = ui_event.reason()
        device = ui_event.device()
        origin, direction = ui_event.ray()

        node = self.node
        collision_geo = node.node(LBState.NODE_COLLIDER).geometry()

        hit_P = hou.Vector3()
        hit_N = hou.Vector3()
        hit_uvw = hou.Vector3()
        hit_prim = collision_geo.intersect(origin, direction, hit_P, hit_N, hit_uvw)
        self.hit_P = hit_P

        if hit_prim == 0:

            pixel_coord = (hit_uvw * 3) - hou.Vector3(1, 1, 0)
            pixel_x = int(pixel_coord[0] * self.bg_res[0])
            pixel_y = int(pixel_coord[1] * self.bg_res[1])

            if device.isCtrlKey():
                with hou.undos.disabler():
                    self.outline.show(False)
                    node.parm(f"bitmap_id{self.current_parm_idx}").set(-1)
                    if reason == hou.uiEventReason.Picked and device.isLeftButton():
                        idx = self.find_top_index([pixel_x, pixel_y], kwargs["sample_mask"])
                        if idx is not None:
                            self.outline.show(True)
                            self.current_parm_idx = idx
                            self.current_id = node.parm(
                                f"bitmap_id{self.current_parm_idx}"
                            ).evalAsInt()
                            self.set_border_geo(hit_P)
            else:
                with hou.undos.disabler():
                    try:
                        node.parmTuple(f"position{self.current_parm_idx}").set(
                            [
                                pixel_x - self.bitmap_res[self.current_id][0] // 2,
                                pixel_y - self.bitmap_res[self.current_id][1] // 2,
                            ]
                        )
                    except AttributeError:
                        # parm was killed, probably through parm editor
                        return

                if reason == hou.uiEventReason.Picked and device.isLeftButton():
                    _, _, depth, _ = self.add_bitmap()
                    updates = {"bitmap_depth_id": depth}
                    self.scene_viewer.hudInfo(hud_values=updates)

                if self.border_mode != Border.none:
                    self.outline.show(True)
                    # TODO: Instead of using hit_P, it would be more accurate
                    # to translate back from pixel_x/y, so that way the snapping
                    # is more apparent.
                    self.set_border_geo(hit_P)

        else:
            self.outline.show(False)

    def onMenuAction(self, kwargs):
        self.border_mode = kwargs["outline_type"]
        self.outline.enable(kwargs["outline_type"]!=Border.none)


def createViewerStateTemplate():
    """ Mandatory entry point to create and return the viewer state 
        template to register. """

    state_typename = "level_builder"
    state_label = "Level Builder"
    state_cat = hou.sopNodeTypeCategory()

    template = hou.ViewerStateTemplate(state_typename, state_label, state_cat)
    template.bindFactory(LBState)
    # template.bindIcon(kwargs["type"].icon())

    menu = hou.ViewerStateMenu("options", "Editor Options")
    # TODO Add hotkey for this
    menu.addToggleItem("sample_mask", "Sample Mask For Selection", True)
    menu.addSeparator()
    menu.addRadioStrip("outline_type", "Bitmap Outline Style", Border.outline)
    menu.addRadioStripItem("outline_type", Border.none, "None")
    menu.addRadioStripItem("outline_type", Border.grid, "Rectangle")
    menu.addRadioStripItem("outline_type", Border.outline, "Outline")
    template.bindMenu(menu)

    return template
