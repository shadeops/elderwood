import base64
import json
import array
import itertools

import numpy

import hou


def multiparm_iter(parm):
    parms = parm.multiParmInstances()
    num = parm.multiParmInstancesPerItem()
    for i in range(0, len(parms), num):
        yield parms[i : i + num]


def encode_volume(vol):
    voxel_array = array.array("f")
    voxel_array.frombytes(vol.allVoxelsAsString())
    bitarray = numpy.packbits(numpy.array(voxel_array, dtype="bool"))
    return str(base64.urlsafe_b64encode(bitarray), "ascii")


def iter_bitmap_parms(node):
    bitmap_parm = node.parm("bitmaps")
    bitmaps = bitmap_parm.eval()
    parm_groups = multiparm_iter(bitmap_parm)

    for bitmap in parm_groups:

        sop, mask, static, start_frame, end_frame = bitmap
        sop = sop.evalAsNode()
        mask = bool(mask.eval())
        static = bool(static.eval())
        if not static:
            start_frame = start_frame.eval()
            end_frame = end_frame.eval()
        else:
            start_frame = None
            end_frame = None

        if not sop:
            continue

        yield (sop, mask, static, start_frame, end_frame)


class VolumeError(hou.Error):
    pass


def get_img_mask_prims(node, get_mask=True, frame=None):
    if frame is not None:
        geo = node.geometryAtFrame(frame)
    else:
        geo = node.geometry()

    img_vol = geo.iterPrims()[0]

    try:
        resx, resy = [int(x) for x in img_vol.resolution()[:2]]
    except AttributeError:
        raise VolumeError("Not a volume")

    mask_vol = None
    if get_mask:
        try:
            mask_vol = geo.iterPrims()[1]
            mask_resx, mask_resy = [int(x) for x in mask_vol.resolution()[:2]]
            if mask_resx != resx or mask_resy != resy:
                raise Exception("Mask resolution does match")

        except (AttributeError, IndexError):
            mask_vol = None

    return img_vol, mask_vol, (resx, resy)


def build_library(node):

    export_bitmaps = []

    for sop, mask, static, start_frame, end_frame in iter_bitmap_parms(node):

        bitmap_group_imgs = []
        bitmap_group = {
            sop.path(): [
                {
                    "metadata": {
                        "static": static,
                        "start_frame": start_frame,
                        "end_frame": end_frame,
                    }
                },
                {"bitmaps": bitmap_group_imgs},
            ]
        }

        export_bitmaps.append(bitmap_group)

        frame_list = [None]
        if not static:
            frame_list = list(range(start_frame, end_frame + 1))

        for frame in frame_list:
            try:
                img_vol, mask_vol, res = get_img_mask_prims(
                    sop, get_mask=mask, frame=frame
                )
            except VolumeError:
                continue

            img_mask = {"img_mask": None}
            has_mask = mask_vol is not None

            if has_mask:
                img_mask["img_mask"] = encode_volume(mask_vol)

            bitmap_obj = {
                "bitmap": [
                    {"spec": [res[0], res[1], has_mask]},
                    {"img": encode_volume(img_vol)},
                    img_mask,
                ]
            }

            bitmap_group_imgs.append(bitmap_obj)

    return {"bitmap_library": export_bitmaps}


def export_callback(node):
    path = node.parm("export_path").eval()
    if not path:
        return
    image_export = build_library(node)
    with open(path, "w") as json_f:
        json.dump(image_export, json_f, indent=1)


def library_to_pts(hda_node, node, frame=None):

    geo = node.geometry()

    bitmap_atr = geo.addAttrib(
        hou.attribType.Point, "bitmap", "", create_local_variable=False
    )
    res_atr = geo.addAttrib(
        hou.attribType.Point, "res", [0, 0], create_local_variable=False
    )
    static_atr = geo.addAttrib(
        hou.attribType.Point, "static", 1, create_local_variable=False
    )
    start_atr = geo.addAttrib(
        hou.attribType.Point, "start_frame", 0, create_local_variable=False
    )
    end_atr = geo.addAttrib(
        hou.attribType.Point, "end_frame", 0, create_local_variable=False
    )
    mask_atr = geo.addAttrib(
        hou.attribType.Point, "has_mask", 0, create_local_variable=False
    )

    for sop, mask, static, start_frame, end_frame in iter_bitmap_parms(hda_node):
        try:
            img_vol, mask_vol, res = get_img_mask_prims(sop, get_mask=mask, frame=frame)
        except VolumeError:
            continue

        pt = geo.createPoint()
        pt.setAttribValue(bitmap_atr, sop.path())
        pt.setAttribValue(static_atr, static)
        if not static:
            pt.setAttribValue(start_atr, start_frame)
            pt.setAttribValue(end_atr, end_frame)

        pt.setAttribValue(res_atr, res)
        pt.setAttribValue(mask_atr, mask_vol is not None)
