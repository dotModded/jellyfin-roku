function VideoPlayer(id, audio_stream_idx = 1, subtitle_idx = -1)

  ' Get video controls and UI
  video = CreateObject("roSGNode", "JFVideo")
  video.id = id
  AddVideoContent(video, audio_stream_idx, subtitle_idx)

  if video.content = invalid
    return invalid
  end if
  jellyfin_blue = "#00a4dcFF"

  video.retrievingBar.filledBarBlendColor = jellyfin_blue
  video.bufferingBar.filledBarBlendColor = jellyfin_blue
  video.trickPlayBar.filledBarBlendColor = jellyfin_blue
  return video
end function

sub AddVideoContent(video, audio_stream_idx = 1, subtitle_idx = -1, playbackPosition = -1)

  video.content = createObject("RoSGNode", "ContentNode")

  meta = ItemMetaData(video.id)
  if meta = invalid then
    video.content = invalid
    return
  end if

  video.content.title = meta.title
  video.showID = meta.showID

  if playbackPosition = -1 then
    playbackPosition = meta.json.UserData.PlaybackPositionTicks
    if playbackPosition > 0 then
      dialogResult = startPlayBackOver(playbackPosition)
      'Dialog returns -1 when back pressed, 0 for resume, and 1 for start over
      if dialogResult = -1 then
        'User pressed back, return invalid and don't load video
        video.content = invalid
        return
      else if dialogResult = 1 then
        'Start Over selected, change position to 0
        playbackPosition = 0
      else if dialogResult = 2 then
        'Mark this item as watched, refresh the page, and return invalid so we don't load the video
        MarkItemWatched(video.id)
        video.content.watched = not video.content.watched
        group = m.scene.focusedChild
        group.timeLastRefresh = CreateObject("roDateTime").AsSeconds()
        group.callFunc("refresh")
        video.content = invalid
        return
      end if
    end if
  end if
  video.content.PlayStart = int(playbackPosition / 10000000)

  ' Call PlayInfo from server
  mediaSourceId = video.id
  if meta.live then mediaSourceId = "" ' Don't send mediaSourceId for Live media
  playbackInfo = ItemPostPlaybackInfo(video.id, mediaSourceId, audio_stream_idx, subtitle_idx, playbackPosition)

  video.videoId = video.id
  video.mediaSourceId = video.id
  video.audioIndex = audio_stream_idx

  if playbackInfo = invalid then
    video.content = invalid
    return
  end if

  params = {}
  video.PlaySessionId = playbackInfo.PlaySessionId

  if meta.live then
    video.content.live = true
    video.content.StreamFormat = "hls"
  end if

  video.container = getContainerType(meta)

  subtitles = sortSubtitles(meta.id, playbackInfo.MediaSources[0].MediaStreams)
  video.Subtitles = subtitles["all"]

  if meta.live then
    video.transcodeParams = {
      "MediaSourceId": playbackInfo.MediaSources[0].Id,
      "LiveStreamId": playbackInfo.MediaSources[0].LiveStreamId,
      "PlaySessionId": video.PlaySessionId
    }
  end if

  video.content.SubtitleTracks = subtitles["text"]

  ' 'TODO: allow user selection of subtitle track before playback initiated, for now set to no subtitles
  video.SelectedSubtitle = -1

  video.directPlaySupported = playbackInfo.MediaSources[0].SupportsDirectPlay

  if video.directPlaySupported then
    params.append({
      "Static": "true",
      "Container": video.container,
      "PlaySessionId": video.PlaySessionId,
      "AudioStreamIndex": audio_stream_idx
    })
    video.content.url = buildURL(Substitute("Videos/{0}/stream", video.id), params)
    video.isTranscoded = false
  else

    ' Get transcoding reason
    video.transcodeReasons = getTranscodeReasons(playbackInfo.MediaSources[0].TranscodingUrl)

    video.content.url = buildURL(playbackInfo.MediaSources[0].TranscodingUrl)
    video.isTranscoded = true
  end if

  video.content = authorize_request(video.content)
  video.content.setCertificatesFile("common:/certs/ca-bundle.crt")

end sub

'
' Extract array of Transcode Reasons from the content URL
' @returns Array of Strings
function getTranscodeReasons(url as string) as object

  regex = CreateObject("roRegex", "&TranscodeReasons=([^&]*)", "")
  match = regex.Match(url)

  if match.count() > 1
    return match[1].Split(",")
  end if

  return []
end function

'Checks available subtitle tracks and puts subtitles in forced, default, and non-default/forced but preferred language at the top
function sortSubtitles(id as string, MediaStreams)
  tracks = { "forced": [], "default": [], "normal": [] }
  'Too many args for using substitute
  dashedid = id.left(8) + "-" + id.mid(8,4) + "-" + id.mid(12,4) + "-" + id.mid(16,4) + "-" + id.right(12)
  prefered_lang = m.user.Configuration.SubtitleLanguagePreference
  for each stream in MediaStreams
    if stream.type = "Subtitle" then

      url = ""
      if(stream.DeliveryUrl <> invalid) then
        url = buildURL(stream.DeliveryUrl)
      end if

      stream = {
        "Track": { "Language" : stream.language, "Description": stream.displaytitle , "TrackName": url },
        "IsTextSubtitleStream": stream.IsTextSubtitleStream,
        "Index": stream.index,
        "IsDefault": stream.IsDefault,
        "IsForced": stream.IsForced,
        "IsExternal": stream.IsExternal
        "IsEncoded": stream.DeliveryMethod = "Encode"
      }
      if stream.isForced then
        trackType = "forced"
      else if stream.IsDefault then
        trackType = "default"
      else
        trackType = "normal"
      end if
      if prefered_lang <> "" and prefered_lang = stream.Track.Language then
        tracks[trackType].unshift(stream)
      else
        tracks[trackType].push(stream)
      end if
    end if
  end for

  tracks["default"].append(tracks["normal"])
  tracks["forced"].append(tracks["default"])

  textTracks = []
  for i = 0 to tracks["forced"].count() - 1
    if tracks["forced"][i].IsTextSubtitleStream then
      tracks["forced"][i].TextIndex = textTracks.count()
      textTracks.push(tracks["forced"][i].Track)
    end if
  end for
  return { "all" : tracks["forced"], "text": textTracks }
end function

'Opens dialog asking user if they want to resume video or start playback over
function startPlayBackOver(time as LongInteger) as integer
  if m.scene.focusedChild.overhangTitle = "Home" then
    return option_dialog([ "Resume playing at " + ticksToHuman(time) + ".", "Start over from the beginning.", "Watched"])
  else
    return option_dialog([ "Resume playing at " + ticksToHuman(time) + ".", "Start over from the beginning."])
  endif
end function

function directPlaySupported(meta as object) as boolean
  devinfo = CreateObject("roDeviceInfo")
  if meta.json.MediaSources[0] <> invalid and meta.json.MediaSources[0].SupportsDirectPlay = false then
    return false
  end if

  if meta.json.MediaStreams[0] = invalid then
    return false
  end if

  streamInfo =  { Codec: meta.json.MediaStreams[0].codec }
  if meta.json.MediaStreams[0].Profile <> invalid and meta.json.MediaStreams[0].Profile.len() > 0 then
    streamInfo.Profile = LCase(meta.json.MediaStreams[0].Profile)
  end if
  if meta.json.MediaSources[0].container <> invalid and meta.json.MediaSources[0].container.len() > 0  then
    'CanDecodeVideo() requires the .container to be format: “mp4”, “hls”, “mkv”, “ism”, “dash”, “ts” if its to direct stream
    if meta.json.MediaSources[0].container = "mov" then 
        streamInfo.Container = "mp4"
    else
    	streamInfo.Container = meta.json.MediaSources[0].container
    end if
  end if

  decodeResult = devinfo.CanDecodeVideo(streamInfo)
  return decodeResult <> invalid and decodeResult.result

end function

function getContainerType(meta as object) as string
  ' Determine the file type of the video file source
  if meta.json.mediaSources = invalid then return ""

  container = meta.json.mediaSources[0].container
  if container = invalid
    container = ""
  else if container = "m4v" or container = "mov"
    container = "mp4"
  end if

  return container
end function

function getAudioFormat(meta as object) as string
  ' Determine the codec of the audio file source
  if meta.json.mediaSources = invalid then return ""

  audioInfo = getAudioInfo(meta)
  if audioInfo.count() = 0 or audioInfo[0].codec = invalid then return ""
  return audioInfo[0].codec
end function

function getAudioInfo(meta as object) as object
  ' Return audio metadata for a given stream
  results = []
  for each source in meta.json.mediaSources[0].mediaStreams
    if source["type"] = "Audio"
      results.push(source)
    end if
  end for
  return results
end function

function ReportPlayback(video, state = "update" as string)

  if video = invalid or video.position = invalid then return invalid

  params = {
    "PlaySessionId": video.PlaySessionId,
    "PositionTicks": int(video.position) * 10000000&,   'Ensure a LongInteger is used
    "IsPaused": (video.state = "paused"),
  }
  if video.content.live then
    params.append({
      "MediaSourceId": video.transcodeParams.MediaSourceId,
      "LiveStreamId": video.transcodeParams.LiveStreamId
    })
  end if
  PlaystateUpdate(video.id, state, params)
end function

function StopPlayback()
  video = m.scene.focusedchild
  video.control = "stop"
  m.device.EnableAppFocusEvent(False)
  video.findNode("playbackTimer").control = "stop"
  ReportPlayback(video, "stop")
end function

function autoPlayNextEpisode(videoID as string, showID as string)
  ' use web client setting
  if m.user.Configuration.EnableNextEpisodeAutoPlay then
    ' query API for next episode ID
    url = Substitute("Shows/{0}/Episodes", showID)
    urlParams = { "UserId": get_setting("active_user")}
    urlParams.Append({ "StartItemId": videoID })
    urlParams.Append({ "Limit": 2 })
    resp = APIRequest(url, urlParams)
    data = getJson(resp)
    
    if data <> invalid and data.Items.Count() = 2 then
      ' remove finished video node
      n = m.scene.getChildCount() - 1
      m.scene.removeChildIndex(n)
      ' setup new video node
      nextVideo = CreateVideoPlayerGroup(data.Items[1].Id)
      m.scene.appendChild(nextVideo)
      nextVideo.setFocus(true)
      nextVideo.control = "play"
      ReportPlayback(nextVideo, "start")
      return nextVideo
    else
      ' can't play next episode
      RemoveCurrentGroup()
    end if
  else
    RemoveCurrentGroup()
  end if
  return invalid
end function
