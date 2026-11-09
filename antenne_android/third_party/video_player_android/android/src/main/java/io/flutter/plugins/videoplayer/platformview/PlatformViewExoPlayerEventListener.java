// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.videoplayer.platformview;

import androidx.annotation.NonNull;
import androidx.annotation.OptIn;
import androidx.media3.common.Format;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.exoplayer.ExoPlayer;
import io.flutter.plugins.videoplayer.ExoPlayerEventListener;
import io.flutter.plugins.videoplayer.VideoPlayerCallbacks;

public final class PlatformViewExoPlayerEventListener extends ExoPlayerEventListener {
  public PlatformViewExoPlayerEventListener(
      @NonNull ExoPlayer exoPlayer, @NonNull VideoPlayerCallbacks events) {
    super(exoPlayer, events);
  }

  @OptIn(markerClass = UnstableApi.class)
  @Override
  protected void sendInitialized() {
    // We can't rely on VideoSize here, because at this point it is not available - the platform
    // view was not created yet. We use the video format instead.
    Format videoFormat = exoPlayer.getVideoFormat();
    // Antenne : sans piste d'image décodable (HEVC ou MPEG-2 sur certaines box, flux audio), le format
    // est nul et le plugin d'origine plantait l'app (NullPointerException). On annonce une image vide :
    // l'app passe alors à mpv.
    if (videoFormat == null) {
      events.onInitialized(0, 0, exoPlayer.getDuration(), 0);
      return;
    }
    RotationDegrees rotationCorrection = RotationDegrees.fromDegrees(videoFormat.rotationDegrees);
    int width = videoFormat.width;
    int height = videoFormat.height;

    // Switch the width/height if video was taken in portrait mode and a rotation
    // correction was detected.
    if (rotationCorrection == RotationDegrees.ROTATE_90
        || rotationCorrection == RotationDegrees.ROTATE_270) {
      width = videoFormat.height;
      height = videoFormat.width;

      rotationCorrection = RotationDegrees.fromDegrees(0);
    }

    events.onInitialized(width, height, exoPlayer.getDuration(), rotationCorrection.getDegrees());
  }
}
