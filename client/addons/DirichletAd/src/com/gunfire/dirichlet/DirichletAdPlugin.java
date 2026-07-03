package com.gunfire.dirichlet;

import android.app.Activity;
import android.util.Log;

import org.godotengine.godot.Godot;
import org.godotengine.godot.plugin.GodotPlugin;
import org.godotengine.godot.plugin.SignalInfo;
import org.godotengine.godot.plugin.UsedByGodot;

import java.util.Collections;
import java.util.HashSet;
import java.util.Set;

import com.tapsdk.tapad.AdRequest;
import com.tapsdk.tapad.TapAdConfig;
import com.tapsdk.tapad.TapAdManager;
import com.tapsdk.tapad.TapAdNative;
import com.tapsdk.tapad.TapAdSdk;
import com.tapsdk.tapad.TapRewardVideoAd;

public class DirichletAdPlugin extends GodotPlugin {
    private static final String TAG = "DirichletAdPlugin";

    private static final int AD_LOAD_FAILED = 500;
    private static final int AD_LOADED = 200;
    private static final int AD_SHOWN = 201;
    private static final int AD_CLOSED = 202;
    private static final int AD_VIDEO_FINISHED = 203;
    private static final int AD_VIDEO_ERROR = 204;
    private static final int AD_REWARD_COMPLETED = 205;
    private static final int AD_SKIPPED = 206;
    private static final int AD_CLICKED = 207;

    private volatile boolean initialized = false;
    private volatile boolean loading = false;
    private TapAdNative adNative = null;
    private TapRewardVideoAd rewardVideoAd = null;
    private boolean rewardShowTriggered = false;

    public DirichletAdPlugin(Godot godot) {
        super(godot);
    }

    @Override
    public String getPluginName() {
        return "DirichletAd";
    }

    @Override
    public Set<SignalInfo> getPluginSignals() {
        Set<SignalInfo> signals = new HashSet<SignalInfo>();
        signals.add(new SignalInfo("onRewardVideoAdCallBack", Integer.class, String.class));
        return signals;
    }

    @UsedByGodot
    public boolean initAd(final String mediaId, final String mediaName, final String mediaKey) {
        return initAd(mediaId, mediaName, mediaKey, true);
    }

    @UsedByGodot
    public boolean initAd(final String mediaId, final String mediaName, final String mediaKey, final boolean debug) {
        final Activity activity = getActivity();
        if (activity == null) {
            Log.e(TAG, "initAd failed: Activity is null");
            return false;
        }
        try {
            final long parsedMediaId = Long.parseLong(safe(mediaId));
            activity.runOnUiThread(new Runnable() {
                @Override
                public void run() {
                    try {
                        TapAdConfig config = new TapAdConfig.Builder()
                                .withMediaId(parsedMediaId)
                                .withMediaName(safe(mediaName))
                                .withMediaKey(safe(mediaKey))
                                .enableDebug(debug)
                                .shakeEnabled(true)
                                .build();
                        TapAdSdk.init(activity.getApplicationContext(), config);
                        adNative = TapAdManager.get().createAdNative(activity);
                        initialized = true;
                        Log.i(TAG, "Dirichlet Ad SDK initialized");
                    } catch (Throwable t) {
                        initialized = false;
                        Log.e(TAG, "initAd failed", t);
                        emitRewardCallback(AD_LOAD_FAILED, "initAd failed: " + t.getMessage());
                    }
                }
            });
            return true;
        } catch (Throwable t) {
            Log.e(TAG, "initAd parse failed", t);
            return false;
        }
    }

    @UsedByGodot
    public boolean isInitialized() {
        return initialized;
    }

    @UsedByGodot
    public String getSdkVersion() {
        try {
            return String.valueOf(TapAdSdk.getVersion());
        } catch (Throwable t) {
            return "unknown";
        }
    }

    @UsedByGodot
    public boolean showRewardVideoAd(final String spaceId, final String rewardName, final String extraInfo, final String userId) {
        final Activity activity = getActivity();
        if (activity == null) {
            emitRewardCallback(AD_LOAD_FAILED, "Activity is null");
            return false;
        }
        if (!initialized) {
            emitRewardCallback(AD_LOAD_FAILED, "SDK is not initialized");
            return false;
        }
        if (adNative == null) {
            adNative = TapAdManager.get().createAdNative(activity);
        }
        if (loading) {
            emitRewardCallback(AD_LOAD_FAILED, "Reward video ad is already loading");
            return false;
        }
        try {
            final long parsedSpaceId = Long.parseLong(safe(spaceId));
            loading = true;
            rewardShowTriggered = false;
            activity.runOnUiThread(new Runnable() {
                @Override
                public void run() {
                    try {
                        AdRequest request = new AdRequest.Builder()
                                .withSpaceId(parsedSpaceId)
                                .withRewardName(defaultString(rewardName, "reward"))
                                .withRewardAmount(1)
                                .withExtra1(safe(extraInfo))
                                .withUserId(safe(userId))
                                .build();
                        adNative.loadRewardVideoAd(request, new TapAdNative.RewardVideoAdListener() {
                            @Override
                            public void onError(int code, String message) {
                                loading = false;
                                emitRewardCallback(AD_LOAD_FAILED, "load failed " + code + ": " + safe(message));
                            }

                            @Override
                            public void onRewardVideoAdLoad(TapRewardVideoAd ad) {
                                loading = false;
                                rewardVideoAd = ad;
                                emitRewardCallback(AD_LOADED, "reward ad loaded");
                                tryShowLoadedRewardAd(activity, ad);
                            }

                            @Override
                            public void onRewardVideoCached(TapRewardVideoAd ad) {
                                rewardVideoAd = ad;
                                emitRewardCallback(AD_LOADED, "reward ad cached");
                                tryShowLoadedRewardAd(activity, ad);
                            }
                        });
                    } catch (Throwable t) {
                        loading = false;
                        Log.e(TAG, "showRewardVideoAd load failed", t);
                        emitRewardCallback(AD_LOAD_FAILED, "load exception: " + t.getMessage());
                    }
                }
            });
            return true;
        } catch (Throwable t) {
            loading = false;
            Log.e(TAG, "showRewardVideoAd parse failed", t);
            emitRewardCallback(AD_LOAD_FAILED, "invalid spaceId: " + safe(spaceId));
            return false;
        }
    }

    private void tryShowLoadedRewardAd(final Activity activity, final TapRewardVideoAd ad) {
        if (rewardShowTriggered) {
            return;
        }
        rewardShowTriggered = true;
        showLoadedRewardAd(activity, ad);
    }

    private void showLoadedRewardAd(final Activity activity, final TapRewardVideoAd ad) {
        if (ad == null) {
            emitRewardCallback(AD_LOAD_FAILED, "loaded ad is null");
            return;
        }
        try {
            ad.setRewardAdInteractionListener(new TapRewardVideoAd.RewardAdInteractionListener() {
                @Override
                public void onAdShow(TapRewardVideoAd ad) {
                    emitRewardCallback(AD_SHOWN, "ad shown");
                }

                @Override
                public void onAdClose(TapRewardVideoAd ad) {
                    emitRewardCallback(AD_CLOSED, "ad closed");
                    disposeRewardAd();
                }

                @Override
                public void onVideoComplete(TapRewardVideoAd ad) {
                    emitRewardCallback(AD_VIDEO_FINISHED, "video completed");
                }

                @Override
                public void onVideoError(TapRewardVideoAd ad) {
                    emitRewardCallback(AD_VIDEO_ERROR, "video error");
                }

                @Override
                public void onRewardVerify(TapRewardVideoAd ad, boolean rewardVerify, int rewardAmount, String rewardName, int errorCode, String errorMsg) {
                    if (rewardVerify) {
                        emitRewardCallback(AD_REWARD_COMPLETED, "reward verified amount=" + rewardAmount + " name=" + safe(rewardName));
                    } else {
                        emitRewardCallback(AD_VIDEO_ERROR, "reward verify failed " + errorCode + ": " + safe(errorMsg));
                    }
                }

                @Override
                public void onSkippedVideo(TapRewardVideoAd ad) {
                    emitRewardCallback(AD_SKIPPED, "video skipped");
                }

                @Override
                public void onAdClick(TapRewardVideoAd ad) {
                    emitRewardCallback(AD_CLICKED, "ad clicked");
                }

                @Override
                public void onAdValidShow(TapRewardVideoAd ad) {
                    // Impression is valid; keep code quiet because game reward depends on onRewardVerify.
                }
            });
            ad.showRewardVideoAd(activity);
        } catch (Throwable t) {
            Log.e(TAG, "show loaded reward ad failed", t);
            emitRewardCallback(AD_VIDEO_ERROR, "show exception: " + t.getMessage());
        }
    }

    @UsedByGodot
    public void disposeRewardAd() {
        try {
            if (rewardVideoAd != null) {
                rewardVideoAd.dispose();
            }
        } catch (Throwable t) {
            Log.w(TAG, "disposeRewardAd failed: " + t.getMessage());
        } finally {
            rewardVideoAd = null;
        }
    }

    private void emitRewardCallback(final int code, final String message) {
        Log.i(TAG, "reward callback " + code + " " + safe(message));
        try {
            emitSignal("onRewardVideoAdCallBack", Integer.valueOf(code), safe(message));
        } catch (Throwable t) {
            Log.e(TAG, "emit reward callback failed", t);
        }
    }

    private static String safe(String value) {
        return value == null ? "" : value;
    }

    private static String defaultString(String value, String fallback) {
        return value == null || value.length() == 0 ? fallback : value;
    }
}
