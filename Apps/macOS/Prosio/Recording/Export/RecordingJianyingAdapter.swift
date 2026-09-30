import Foundation

// Modified schema adapter and embedded templates based on pyJianYingDraft,
// Copyright 2024 Gary Guan, Apache-2.0. Reference revision:
// 6bb2d06a713f7b58e1375269daec835a03882086.
// This Swift implementation is intentionally experimental until editor acceptance.
@MainActor
enum RecordingJianyingAdapter {
    static func write(session: RecordingSessionManifest, media: [RecordingMediaInfo], directory: URL, finalDirectory: URL) throws {
        var draft = try JSONSerialization.jsonObject(with: Data(contentTemplate.utf8)) as! [String: Any]
        var materials = draft["materials"] as! [String: Any]
        var videos: [[String: Any]] = [], audios: [[String: Any]] = [], speeds: [[String: Any]] = []
        var tracks: [[String: Any]] = []
        for (trackIndex, source) in session.sources.enumerated() {
            var segments: [[String: Any]] = []
            for info in media.filter({ $0.source.id == source.id }).sorted(by: { $0.segment.timelineStartMicroseconds < $1.segment.timelineStartMicroseconds }) {
                let id = info.segment.id.uuidString
                let speedID = UUID().uuidString
                let duration = Int64((info.duration.seconds * 1_000_000).rounded())
                speeds.append(["id": speedID, "type": "speed", "mode": 0, "speed": 1.0, "curve_speed": NSNull()])
                if info.isVideo {
                    videos.append(["id": id, "material_id": id, "local_material_id": id, "material_name": source.name, "path": info.url.path, "media_path": "", "type": "video", "duration": duration, "width": info.width ?? 1920, "height": info.height ?? 1080, "category_name": "local", "category_id": "", "check_flag": 63487, "audio_fade": NSNull(), "crop_ratio": "free", "crop_scale": 1.0, "crop": ["upper_left_x": 0.0, "upper_left_y": 0.0, "upper_right_x": 1.0, "upper_right_y": 0.0, "lower_left_x": 0.0, "lower_left_y": 1.0, "lower_right_x": 1.0, "lower_right_y": 1.0]])
                } else {
                    audios.append(["id": id, "local_material_id": id, "music_id": id, "name": source.name, "path": info.url.path, "duration": duration, "type": "extract_music", "app_id": 0, "category_id": "", "category_name": "local", "check_flag": 3, "copyright_limit_type": "none", "effect_id": "", "formula_id": "", "source_platform": 0, "wave_points": []])
                }
                var segment: [String: Any] = ["id": UUID().uuidString, "material_id": id, "target_timerange": ["start": info.segment.timelineStartMicroseconds, "duration": info.segment.durationMicroseconds], "source_timerange": ["start": info.segment.mediaStartMicroseconds, "duration": info.segment.durationMicroseconds], "extra_material_refs": [speedID], "speed": 1.0, "volume": 1.0, "last_nonzero_volume": 1.0, "is_tone_modify": false, "reverse": false, "visible": true, "track_attribute": 0, "track_render_index": 0, "render_index": trackIndex, "common_keyframes": [], "keyframe_refs": [], "enable_adjust": true, "enable_color_correct_adjust": false, "enable_color_curves": true, "enable_color_match_adjust": false, "enable_color_wheels": true, "enable_lut": true, "enable_smart_color_adjust": false]
                if info.isVideo {
                    segment["volume"] = 0.0 // Video sources are silent; audio remains on its own tracks.
                    segment["clip"] = ["alpha": 1.0, "flip": ["horizontal": false, "vertical": false], "rotation": 0.0, "scale": ["x": 1.0, "y": 1.0], "transform": ["x": 0.0, "y": 0.0]]
                    segment["uniform_scale"] = ["on": true, "value": 1.0]
                    segment["hdr_settings"] = ["intensity": 1.0, "mode": 1, "nits": 1000]
                } else { segment["clip"] = NSNull(); segment["hdr_settings"] = NSNull() }
                segments.append(segment)
            }
            guard !segments.isEmpty else { continue }
            tracks.append(["id": UUID().uuidString, "name": source.name, "is_default_name": false, "attribute": 0, "flag": 0, "type": (source.kind == .screen || source.kind == .camera) ? "video" : "audio", "segments": segments])
        }
        materials["videos"] = videos; materials["audios"] = audios; materials["speeds"] = speeds
        draft["fps"] = media.first(where: \.isVideo)?.frameDuration.map { 1 / $0.seconds } ?? 30.0
        draft["materials"] = materials; draft["tracks"] = tracks; draft["id"] = session.id.uuidString; draft["name"] = session.title; draft["duration"] = session.durationMicroseconds
        draft["canvas_config"] = ["width": media.first(where: \.isVideo)?.width ?? 1920, "height": media.first(where: \.isVideo)?.height ?? 1080, "ratio": "original"]
        var config = draft["config"] as! [String: Any]; config["maintrack_adsorb"] = false; draft["config"] = config
        var meta = try JSONSerialization.jsonObject(with: Data(metaTemplate.utf8)) as! [String: Any]
        meta["draft_id"] = session.id.uuidString; meta["draft_name"] = session.title; meta["draft_fold_path"] = finalDirectory.path; meta["draft_root_path"] = finalDirectory.deletingLastPathComponent().path; meta["tm_duration"] = session.durationMicroseconds
        try JSONSerialization.data(withJSONObject: draft, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("draft_content.json"), options: .atomic)
        try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("draft_meta_info.json"), options: .atomic)
        try Data(licenseTemplate.utf8).write(to: directory.appendingPathComponent("Apache-2.0.txt"), options: .atomic)
        let attribution = "Modified draft templates based on pyJianYingDraft, Copyright 2024 Gary Guan. Apache-2.0. Reference revision 6bb2d06a713f7b58e1375269daec835a03882086. Swift media / timing adapter by Prosio. https://github.com/GuanYixuan/pyJianYingDraft"
        try Data(attribution.utf8).write(to: directory.appendingPathComponent("THIRD-PARTY-NOTICES.txt"), options: .atomic)
    }
    private static let contentTemplate = #"""
{
    "canvas_config": {
        "height": 1080,
        "ratio": "original",
        "width": 1920
    },
    "color_space": 0,
    "config": {
        "adjust_max_index": 1,
        "attachment_info": [],
        "combination_max_index": 1,
        "export_range": null,
        "extract_audio_last_index": 1,
        "lyrics_recognition_id": "",
        "lyrics_sync": true,
        "lyrics_taskinfo": [],
        "maintrack_adsorb": true,
        "material_save_mode": 0,
        "multi_language_current": "none",
        "multi_language_list": [],
        "multi_language_main": "none",
        "multi_language_mode": "none",
        "original_sound_last_index": 1,
        "record_audio_last_index": 1,
        "sticker_max_index": 1,
        "subtitle_keywords_config": null,
        "subtitle_recognition_id": "",
        "subtitle_sync": true,
        "subtitle_taskinfo": [],
        "system_font_list": [],
        "video_mute": false,
        "zoom_info_params": null
    },
    "cover": null,
    "create_time": 0,
    "duration": 0,
    "extra_info": null,
    "fps": 30.0,
    "free_render_index_mode_on": false,
    "group_container": null,
    "id": "91E08AC5-22FB-47e2-9AA0-7DC300FAEA2B",
    "keyframe_graph_list": [],
    "keyframes": {
        "adjusts": [],
        "audios": [],
        "effects": [],
        "filters": [],
        "handwrites": [],
        "stickers": [],
        "texts": [],
        "videos": []
    },
    "last_modified_platform": {
        "app_id": 3704,
        "app_source": "lv",
        "app_version": "5.9.0",
        "os": "windows"
    },
    "platform": {
        "app_id": 3704,
        "app_source": "lv",
        "app_version": "5.9.0",
        "os": "windows"
    },
    "materials": {
        "ai_translates": [],
        "audio_balances": [],
        "audio_effects": [],
        "audio_fades": [],
        "audio_track_indexes": [],
        "audios": [],
        "beats": [],
        "canvases": [],
        "chromas": [],
        "color_curves": [],
        "digital_humans": [],
        "drafts": [],
        "effects": [],
        "flowers": [],
        "green_screens": [],
        "handwrites": [],
        "hsl": [],
        "images": [],
        "log_color_wheels": [],
        "loudnesses": [],
        "manual_deformations": [],
        "masks": [],
        "material_animations": [],
        "material_colors": [],
        "multi_language_refs": [],
        "placeholders": [],
        "plugin_effects": [],
        "primary_color_wheels": [],
        "realtime_denoises": [],
        "shapes": [],
        "smart_crops": [],
        "smart_relights": [],
        "sound_channel_mappings": [],
        "speeds": [],
        "stickers": [],
        "tail_leaders": [],
        "text_templates": [],
        "texts": [],
        "time_marks": [],
        "transitions": [],
        "video_effects": [],
        "video_trackings": [],
        "videos": [],
        "vocal_beautifys": [],
        "vocal_separations": []
    },
    "mutable_config": null,
    "name": "",
    "new_version": "110.0.0",
    "relationships": [],
    "render_index_track_mode_on": false,
    "retouch_cover": null,
    "source": "default",
    "static_cover_image_path": "",
    "time_marks": null,
    "tracks": [
    ],
    "update_time": 0,
    "version": 360000
}
"""#
    private static let metaTemplate = #"""
{
	"cloud_package_completed_time": "",
	"draft_cloud_capcut_purchase_info": "",
	"draft_cloud_last_action_download": false,
	"draft_cloud_materials": [],
	"draft_cloud_purchase_info": "",
	"draft_cloud_template_id": "",
	"draft_cloud_tutorial_info": "",
	"draft_cloud_videocut_purchase_info": "",
	"draft_cover": "",
	"draft_deeplink_url": "",
	"draft_enterprise_info": {
		"draft_enterprise_extra": "",
		"draft_enterprise_id": "",
		"draft_enterprise_name": "",
		"enterprise_material": []
	},
	"draft_fold_path": "",
	"draft_id": "BC69C7CD-7C5E-4185-B284-AF3E1047A664",
	"draft_is_ai_packaging_used": false,
	"draft_is_ai_shorts": false,
	"draft_is_ai_translate": false,
	"draft_is_article_video_draft": false,
	"draft_is_from_deeplink": "false",
	"draft_is_invisible": false,
	"draft_materials": [
		{
			"type": 0,
			"value": []
		},
		{
			"type": 1,
			"value": []
		},
		{
			"type": 2,
			"value": []
		},
		{
			"type": 3,
			"value": []
		},
		{
			"type": 6,
			"value": []
		},
		{
			"type": 7,
			"value": []
		},
		{
			"type": 8,
			"value": []
		}
	],
	"draft_materials_copied_info": [],
	"draft_name": "",
	"draft_new_version": "",
	"draft_removable_storage_device": "",
	"draft_root_path": "",
	"draft_segment_extra_info": [],
	"draft_type": "",
	"tm_draft_cloud_completed": "",
	"tm_draft_cloud_modified": 0,
	"tm_draft_removed": 0,
	"tm_duration": 0
}
"""#
    private static let licenseTemplate = #"""
                                 Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/

   TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

   1. Definitions.

      "License" shall mean the terms and conditions for use, reproduction,
      and distribution as defined by Sections 1 through 9 of this document.

      "Licensor" shall mean the copyright owner or entity authorized by
      the copyright owner that is granting the License.

      "Legal Entity" shall mean the union of the acting entity and all
      other entities that control, are controlled by, or are under common
      control with that entity. For the purposes of this definition,
      "control" means (i) the power, direct or indirect, to cause the
      direction or management of such entity, whether by contract or
      otherwise, or (ii) ownership of fifty percent (50%) or more of the
      outstanding shares, or (iii) beneficial ownership of such entity.

      "You" (or "Your") shall mean an individual or Legal Entity
      exercising permissions granted by this License.

      "Source" form shall mean the preferred form for making modifications,
      including but not limited to software source code, documentation
      source, and configuration files.

      "Object" form shall mean any form resulting from mechanical
      transformation or translation of a Source form, including but
      not limited to compiled object code, generated documentation,
      and conversions to other media types.

      "Work" shall mean the work of authorship, whether in Source or
      Object form, made available under the License, as indicated by a
      copyright notice that is included in or attached to the work
      (an example is provided in the Appendix below).

      "Derivative Works" shall mean any work, whether in Source or Object
      form, that is based on (or derived from) the Work and for which the
      editorial revisions, annotations, elaborations, or other modifications
      represent, as a whole, an original work of authorship. For the purposes
      of this License, Derivative Works shall not include works that remain
      separable from, or merely link (or bind by name) to the interfaces of,
      the Work and Derivative Works thereof.

      "Contribution" shall mean any work of authorship, including
      the original version of the Work and any modifications or additions
      to that Work or Derivative Works thereof, that is intentionally
      submitted to Licensor for inclusion in the Work by the copyright owner
      or by an individual or Legal Entity authorized to submit on behalf of
      the copyright owner. For the purposes of this definition, "submitted"
      means any form of electronic, verbal, or written communication sent
      to the Licensor or its representatives, including but not limited to
      communication on electronic mailing lists, source code control systems,
      and issue tracking systems that are managed by, or on behalf of, the
      Licensor for the purpose of discussing and improving the Work, but
      excluding communication that is conspicuously marked or otherwise
      designated in writing by the copyright owner as "Not a Contribution."

      "Contributor" shall mean Licensor and any individual or Legal Entity
      on behalf of whom a Contribution has been received by Licensor and
      subsequently incorporated within the Work.

   2. Grant of Copyright License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      copyright license to reproduce, prepare Derivative Works of,
      publicly display, publicly perform, sublicense, and distribute the
      Work and such Derivative Works in Source or Object form.

   3. Grant of Patent License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      (except as stated in this section) patent license to make, have made,
      use, offer to sell, sell, import, and otherwise transfer the Work,
      where such license applies only to those patent claims licensable
      by such Contributor that are necessarily infringed by their
      Contribution(s) alone or by combination of their Contribution(s)
      with the Work to which such Contribution(s) was submitted. If You
      institute patent litigation against any entity (including a
      cross-claim or counterclaim in a lawsuit) alleging that the Work
      or a Contribution incorporated within the Work constitutes direct
      or contributory patent infringement, then any patent licenses
      granted to You under this License for that Work shall terminate
      as of the date such litigation is filed.

   4. Redistribution. You may reproduce and distribute copies of the
      Work or Derivative Works thereof in any medium, with or without
      modifications, and in Source or Object form, provided that You
      meet the following conditions:

      (a) You must give any other recipients of the Work or
          Derivative Works a copy of this License; and

      (b) You must cause any modified files to carry prominent notices
          stating that You changed the files; and

      (c) You must retain, in the Source form of any Derivative Works
          that You distribute, all copyright, patent, trademark, and
          attribution notices from the Source form of the Work,
          excluding those notices that do not pertain to any part of
          the Derivative Works; and

      (d) If the Work includes a "NOTICE" text file as part of its
          distribution, then any Derivative Works that You distribute must
          include a readable copy of the attribution notices contained
          within such NOTICE file, excluding those notices that do not
          pertain to any part of the Derivative Works, in at least one
          of the following places: within a NOTICE text file distributed
          as part of the Derivative Works; within the Source form or
          documentation, if provided along with the Derivative Works; or,
          within a display generated by the Derivative Works, if and
          wherever such third-party notices normally appear. The contents
          of the NOTICE file are for informational purposes only and
          do not modify the License. You may add Your own attribution
          notices within Derivative Works that You distribute, alongside
          or as an addendum to the NOTICE text from the Work, provided
          that such additional attribution notices cannot be construed
          as modifying the License.

      You may add Your own copyright statement to Your modifications and
      may provide additional or different license terms and conditions
      for use, reproduction, or distribution of Your modifications, or
      for any such Derivative Works as a whole, provided Your use,
      reproduction, and distribution of the Work otherwise complies with
      the conditions stated in this License.

   5. Submission of Contributions. Unless You explicitly state otherwise,
      any Contribution intentionally submitted for inclusion in the Work
      by You to the Licensor shall be under the terms and conditions of
      this License, without any additional terms or conditions.
      Notwithstanding the above, nothing herein shall supersede or modify
      the terms of any separate license agreement you may have executed
      with Licensor regarding such Contributions.

   6. Trademarks. This License does not grant permission to use the trade
      names, trademarks, service marks, or product names of the Licensor,
      except as required for reasonable and customary use in describing the
      origin of the Work and reproducing the content of the NOTICE file.

   7. Disclaimer of Warranty. Unless required by applicable law or
      agreed to in writing, Licensor provides the Work (and each
      Contributor provides its Contributions) on an "AS IS" BASIS,
      WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
      implied, including, without limitation, any warranties or conditions
      of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
      PARTICULAR PURPOSE. You are solely responsible for determining the
      appropriateness of using or redistributing the Work and assume any
      risks associated with Your exercise of permissions under this License.

   8. Limitation of Liability. In no event and under no legal theory,
      whether in tort (including negligence), contract, or otherwise,
      unless required by applicable law (such as deliberate and grossly
      negligent acts) or agreed to in writing, shall any Contributor be
      liable to You for damages, including any direct, indirect, special,
      incidental, or consequential damages of any character arising as a
      result of this License or out of the use or inability to use the
      Work (including but not limited to damages for loss of goodwill,
      work stoppage, computer failure or malfunction, or any and all
      other commercial damages or losses), even if such Contributor
      has been advised of the possibility of such damages.

   9. Accepting Warranty or Additional Liability. While redistributing
      the Work or Derivative Works thereof, You may choose to offer,
      and charge a fee for, acceptance of support, warranty, indemnity,
      or other liability obligations and/or rights consistent with this
      License. However, in accepting such obligations, You may act only
      on Your own behalf and on Your sole responsibility, not on behalf
      of any other Contributor, and only if You agree to indemnify,
      defend, and hold each Contributor harmless for any liability
      incurred by, or claims asserted against, such Contributor by reason
      of your accepting any such warranty or additional liability.

   END OF TERMS AND CONDITIONS

   APPENDIX: How to apply the Apache License to your work.

      To apply the Apache License to your work, attach the following
      boilerplate notice, with the fields enclosed by brackets "[]"
      replaced with your own identifying information. (Don't include
      the brackets!)  The text should be enclosed in the appropriate
      comment syntax for the file format. We also recommend that a
      file or class name and description of purpose be included on the
      same "printed page" as the copyright notice for easier
      identification within third-party archives.

   Copyright 2024 Gary Guan

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.

"""#
}
