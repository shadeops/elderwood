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
        yield parms[i:i+num]

def encode_volume(vol):
    voxel_array = array.array("f")
    voxel_array.frombytes(vol.allVoxelsAsString())
    bitarray = numpy.packbits(numpy.array(voxel_array, dtype="bool"))
    return str(base64.urlsafe_b64encode(bitarray),"ascii")

def build_library(node):
    bitmap_parm = node.parm("bitmaps")
    bitmaps = bitmap_parm.eval()
    parm_groups = multiparm_iter(bitmap_parm)

    export_bitmaps = []

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

        bitmap_group_imgs = []
        bitmap_group = {
            sop.path() : [
                {"metadata" : {
                    "static"  : static,
                    "start_frame" : start_frame,
                    "end_frame" : end_frame,
                }},
                {"bitmaps" : bitmap_group_imgs},
            ]
        }

        export_bitmaps.append(bitmap_group)

        frame_list = []
        if static:
            frame_list = [hou.intFrame(),]
        else:
            frame_list = list(range(start_frame, end_frame+1))

        for frame in frame_list:
            geo = sop.geometryAtFrame(frame)
            sop.geometry
            img_vol = geo.iterPrims()[0]

            try:
                mask_vol = geo.iterPrims()[1]
            except IndexError:
                mask_vol = None

            try:
                resx,resy = [int(x) for x in img_vol.resolution()[:2]]
            except AttributeError:
                # Not a volume
                continue

            img_mask = {"img_mask" : None}
            has_mask = mask and mask_vol is not None

            if has_mask:
                mask_resx, mask_resy = [int(x) for x in mask_vol.resolution()[:2]]
                if mask_resx != resx or mask_resy != resy:
                    raise Exception("Mask resolution does match")
                img_mask["img_mask"] = encode_volume(mask_vol)

            bitmap_obj = {"bitmap" : [
                {"spec" : [resx, resy, has_mask]},
                {"img" : encode_volume(img_vol)},
                img_mask
            ]}

            bitmap_group_imgs.append(bitmap_obj)

    return {"bitmap_library" : export_bitmaps}

def export_callback(node):
    path = node.parm("export_path").eval()
    image_export = build_library(node)
    with open(path, "w") as json_f:
        json.dump(image_export, json_f, indent=1)

def library_to_pts(hda_node, node):
    geo = node.geometry()
    library_data = build_library(hda_node)

    bitmap_atr = geo.addAttrib(hou.attribType.Point, "bitmap", "")
    res_atr = geo.addAttrib(hou.attribType.Point, "res", [0,0])
    static_atr = geo.addAttrib(hou.attribType.Point, "static", 1)
    start_atr = geo.addAttrib(hou.attribType.Point, "start_frame", 0)
    end_atr = geo.addAttrib(hou.attribType.Point, "end_frame", 0)
    mask_atr = geo.addAttrib(hou.attribType.Point, "has_mask", 0)


    for bitset in library_data["bitmap_library"]:
        pt = geo.createPoint()
        name, bitdata = next(iter(bitset.items()))
        pt.setAttribValue(bitmap_atr, name)

        metadata,bitmaps = bitdata
        static = metadata["metadata"]["static"]
        pt.setAttribValue(static_atr, static)
        if not static:
            pt.setAttribValue(start_atr, metadata["metadata"]["start_frame"])
            pt.setAttribValue(end_atr, metadata["metadata"]["end_frame"])
        spec = bitmaps["bitmaps"][0]["bitmap"][0]["spec"]
        pt.setAttribValue(res_atr, (spec[0], spec[1]))
        pt.setAttribValue(mask_atr, spec[2])

