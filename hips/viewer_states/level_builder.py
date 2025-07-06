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

class Element:
    def __init__(self, *args, **kwargs):
        if len(args) == 1 and isinstance(arg[0], Element):
            self.bitmap_id = arg[0].bitmap_id
            self.pos = arg[0].pos
            self.depth = args[0].depth
            self.frame_offset = args[0].frame_offset
            self.flip = args[0].flip
        else:
            self.bitmap_id = kwargs.get("bitmap_id", 0)
            self.pos = kwargs.get("pos", (0,0))
            self.depth = kwargs.get("depth", -1)
            self.frame_offset = kwargs.get("frame_offset", 0)
            self.flip = kwargs.get("flip", False)

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
        self.current_id = 0
        self.library_size = 0
        self.bg_res = [0, 0]
        self.bitmap_names = []
        self.bitmap_res = []
        self.hit_P = hou.Vector3()
        self.in_select_mode = False
        self.picked_index = None
        self.last_element = None

        # Menu Options
        self.auto_inc_depth = True
        self.border_mode = Border.outline

        self.border_geo = None
        self.outline_geos = []

        self.outline = hou.SimpleDrawable(
            self.scene_viewer, hou.Geometry(), "bitmap_border"
        )

    # TODO add flip X

    def set_border_geo(self, pos, bitmap_id = None):
        bitmap_id = self.current_id if bitmap_id is None else bitmap_id
        if bitmap_id < 0 or self.border_mode == Border.none:
            return
        base_geo = (
            self.border_geo
            if self.border_mode == Border.grid
            else self.outline_geos[bitmap_id]
        )
        geo = hou.Geometry()
        geo.merge(base_geo)
        scale = hou.hmath.buildScale(
            self.bitmap_res[bitmap_id][0] / self.bg_res[0],
            self.bitmap_res[bitmap_id][1] / self.bg_res[1],
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
            bitmap_id = element["bitmap_id#"]
            if bitmap_id < 0:
                continue
            resx, resy = self.bitmap_res[bitmap_id]
            vx = int(pixel_coord[0] - x)
            vy = int(pixel_coord[1] - y)
            vy = resy - vy
            if vx >= 0 and vx < resx and vy >= 0 and vy < resy:
                if sample_mask:
                    if mask_prims[bitmap_id].voxel((vx, vy, 0)):
                        return element["index"], bitmap_id, (x,y)
                else:
                    return element["index"], bitmap_id, (x,y)

        return None

    def bitmap_values(self, index=None):
        node = self.node
        idx = self.current_parm_idx if index is None else index
        return Element(
            bitmap_id = node.parm(f"bitmap_id{idx}").evalAsInt(),
            depth = node.parm(f"depth{idx}").evalAsInt(),
            pos = node.parmTuple(f"position{idx}").eval(),
            offset = node.parmTuple(f"frame_offset{idx}").eval(),
        )

    def get_indexed_parm(self, name, idx=None):
        idx = self.current_parm_idx if idx is None else idx
        parm = self.node.parm(f"{name}{idx}")
        if parm is None:
            raise ValueError(f"'elements' multiparm does not have idx ({idx})")
        return parm

    def add_bitmap(self):
        node = self.node
        # Fetch current values, and copy them into the new parm, but increment depth
        # We first check to see if there was a "last element" which could have been
        # one that was deleted or previously selected then unpicked
        # If there isn't one, then we use the current_parm_idx
        # and if that isn't valid then we just create a fresh one.
        if self.last_element is not None:
            element = self.last_element
            # Clear the last element now that we have used it
            self.last_element = None
        elif self.current_parm_idx:
            element = self.bitmap_values()
        else:
            element = Element()

        element.bitmap_id = max(element.bitmap_id, 0)
        if self.auto_inc_depth:
            element.depth += 1

        with hou.undos.disabler():
            self.current_parm_idx = self.elements_parm.evalAsInt() + 1
            self.elements_parm.set(self.current_parm_idx)
            node.parm(f"bitmap_id{self.current_parm_idx}").set(element.bitmap_id)
            node.parm(f"depth{self.current_parm_idx}").set(element.depth)
            node.parmTuple(f"position{self.current_parm_idx}").set(element.pos)

        return element

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

        self.collision_geo = node.node(LBState.NODE_COLLIDER).geometry()

        bg_geo = node.node(LBState.NODE_BG_IMG).geometry()
        self.bg_res = bg_geo.iterPrims()[0].resolution()

        geo = node.node(LBState.NODE_BITMAP_LIB).geometry()
        lr = geo.pointIntAttribValues("res")
        self.bitmap_res = list(zip(lr[::2], lr[1::2]))
        self.library_size = len(geo.iterPoints())
        self.bitmap_names = geo.pointStringAttribValues("bitmap")

        self.current_parm_idx = self.elements_parm.evalAsInt()
        element = self.add_bitmap()
        self.current_id = element.bitmap_id

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
                    "value": element.depth,
                    "id": "bitmap_depth_id",
                },
                {
                    "type": "plain",
                    "label": "Mode",
                    "value": "Placement",
                    "id": "bitmap_mode",
                },
                {
                    # Originally this was suppose to just show the selected bitmap
                    # and would only be visible during the selection mode, but once
                    # made visible I can't seem to hide it again. So instead this will
                    # always show the current parm idx being evaluated
                    # TODO: This lack of updating of visible might be due to me passing
                    #           a value. As a test, see if just passing {"visible" : False}
                    #           is sufficient.
                    # Knowing the current bitmap index is useful so even if we can get
                    # "visible" working, the current behavior is better
                    "type": "plain",
                    "label": "Current Bitmap Index",
                    "value": None,
                    "id": "bitmap_selection",
                },
                {"type": "divider", "label": "Keys"},
                {"type": "plain", "label": "Choose Bitmap", "key": "mousewheel"},
                {"type": "plain", "label": "Modify Depth", "key": "Shift mousewheel"},
                {"type": "plain", "label": "Select Bitmap", "key": "Ctrl LMB"},
                {"type": "plain", "label": "Delete Bitmap", "key": "Ctrl MMB"},
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
        if self.current_parm_idx is not None:
            self.elements_parm.removeMultiParmInstance(self.current_parm_idx - 1)

    def onMouseWheelEvent(self, kwargs):
        device = kwargs["ui_event"].device()
        node = self.node

        idx = self.current_parm_idx
        if idx is None:
            return True
        scroll = device.mouseWheel()

        if device.isShiftKey():
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

        hit_P = hou.Vector3()
        hit_N = hou.Vector3()
        hit_uvw = hou.Vector3()
        hit_prim = self.collision_geo.intersect(origin, direction, hit_P, hit_N, hit_uvw)

        updates = {}

        if hit_prim == 0:

            pixel_coord = (hit_uvw * 3) - hou.Vector3(1, 1, 0)
            pixel_x = int(pixel_coord[0] * self.bg_res[0])
            pixel_y = int(pixel_coord[1] * self.bg_res[1])

            if device.isCtrlKey():
                # The Ctrl key is being pressed so we now have entered a select
                # state. If we were previously in a placement state, we need to
                # remove the index that was currently being used to paint
                if not self.in_select_mode:
                    self.elements_parm.removeMultiParmInstance(self.current_parm_idx - 1)
                    self.current_parm_idx = None
                    self.current_id = -1
                self.in_select_mode = True

                found = self.find_top_index([pixel_x, pixel_y], kwargs["sample_mask"])

                if self.picked_index is not None:
                    self.outline.show(True)

                if found is not None:
                    # Something is under our cursor
                    idx, selected_id, pixel_pos = found
                    uv_x = pixel_pos[0] + self.bitmap_res[selected_id][0] // 2
                    uv_x /= self.bg_res[0]
                    uv_x += 1
                    uv_x /= 3
                    uv_y = pixel_pos[1] + self.bitmap_res[selected_id][1] // 2
                    uv_y /= self.bg_res[1]
                    uv_y += 1
                    uv_y /= 3
                    sprite_P = self.collision_geo.prims()[0].positionAt(uv_x, uv_y)

                    # If nothing is selected then we want to highlight it
                    if self.picked_index is None:
                        self.outline.show(True)
                        self.set_border_geo(sprite_P, selected_id)

                    if reason == hou.uiEventReason.Picked:
                        # Something has been picked
                        if device.isLeftButton():
                            # If nothing was previously selected then our
                            # border geo will have been already updated.
                            # However if there had previously been a pick we'll
                            # need to update here.
                            self.last_element = self.bitmap_values(idx)
                            self.current_id = selected_id
                            self.current_parm_idx = idx
                            self.picked_index = idx
                            if self.picked_index is not None:
                                self.set_border_geo(sprite_P, selected_id)
                                self.hit_P = sprite_P
                            self.outline.show(True)
                        elif device.isMiddleButton():
                            # We have deleted something and should hide the outline
                            # also our current state is invalidated
                            self.last_element = self.bitmap_values(idx)
                            self.picked_index = None
                            self.current_parm_idx = None
                            self.current_id = -1
                            self.elements_parm.removeMultiParmInstance(idx-1)
                            self.outline.show(False)
                elif reason == hou.uiEventReason.Picked and device.isLeftButton():
                    # If there is nothing under our cursor and we clicked
                    # we unselect the previous pick and hide the outline
                    self.picked_index = None
                    self.outline.show(False)
                elif self.picked_index is None:
                    # Last if there isn't a bitmap under our cursor and nothing
                    # has been picked make sure not to show the outline
                    self.outline.show(False)

            else:

                # We are now in a Placement state. This is our "default" state
                # If we previously were in a Selection state and is possible that
                # our current state was invalidate through a deletion. We want to
                # create a new bitmap if our state has changed and we have nothing
                # selected.
                if self.in_select_mode and self.picked_index is None:
                    # There is a question of *what* to create our new bitmap as
                    # The defaults? The last of elements_parm? The previously
                    # deleted or picked bitmap?
                    # For now, we'll go with defaults
                    element = self.add_bitmap()
                    self.current_id = element.bitmap_id

                self.hit_P = hit_P
                self.picked_index = None
                self.in_select_mode = False

                with hou.undos.disabler():
                    self.node.parmTuple(f"position{self.current_parm_idx}").set(
                        [
                            pixel_x - self.bitmap_res[self.current_id][0] // 2,
                            pixel_y - self.bitmap_res[self.current_id][1] // 2,
                        ]
                    )

                if reason == hou.uiEventReason.Picked and device.isLeftButton():
                    element = self.add_bitmap()
                    updates["bitmap_depth_id"] = element.depth

                if self.border_mode != Border.none:
                    self.outline.show(True)
                    # TODO: Instead of using hit_P, it would be more accurate
                    # to translate back from pixel_x/y, so that way the snapping
                    # is more apparent.
                    self.set_border_geo(hit_P)
            updates["bitmap_mode"] = "Selection" if self.in_select_mode else "Placement"
        else:
            self.outline.show(False)
        updates["bitmap_selection"] = {"value": self.current_parm_idx}
        self.scene_viewer.hudInfo(values=updates)

    def onMenuAction(self, kwargs):
        self.border_mode = kwargs["outline_type"]
        self.outline.enable(kwargs["outline_type"] != Border.none)
        self.auto_inc_depth(kwargs["auto_depth"])


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
    menu.addToggleItem("auto_depth", "Auto Increment Depth", True)
    menu.addSeparator()
    menu.addRadioStrip("outline_type", "Bitmap Outline Style", Border.outline)
    menu.addRadioStripItem("outline_type", Border.none, "None")
    menu.addRadioStripItem("outline_type", Border.grid, "Rectangle")
    menu.addRadioStripItem("outline_type", Border.outline, "Outline")
    template.bindMenu(menu)

    return template
