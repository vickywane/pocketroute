// Firebase AI Logic hybrid inference for the PWA: Chrome's built-in model on
// the device when it's there, Gemini in the cloud when the passenger opted in
// and is online. Both read a message into the same JSON fields as the iOS app;
// assistant.js grounds the reading and decides every route fact.
//
// The SDK and the web app config load only when a model is wanted. The config
// comes from Firebase Hosting's reserved /__/firebase/init.json, so no keys
// live in this repository. Anything that fails leaves keyword rules in charge.

import { MODEL_INSTRUCTIONS, MODEL_SCHEMA, modelPrompt, turnFromModel } from "./assistant.js";

const SDK = "https://www.gstatic.com/firebasejs/13.2.0";
export const DEFAULT_MODEL = "gemini-3.1-flash-lite";
// The "PocketRoute Web" app in the Firebase project. Hosting's init.json
// carries the project's keys but not this id, because the site isn't linked
// to an app; the id itself isn't a secret.
const WEB_APP_ID = "1:70786883109:web:4ea32be141ac9f57baa9cc";
// App Check (reCAPTCHA Enterprise) protects the Gemini calls. The site key is
// public by design. On localhost the SDK prints a debug token to the console
// instead; register it under App Check → Apps → PocketRoute Web → Manage debug tokens.
export const APP_CHECK_SITE_KEY = "";

let sdk = null;
const models = new Map();

async function config() {
  for (const url of ["/__/firebase/init.json", "/firebase-config.json"]) {
    try {
      const response = await fetch(url);
      if (!response.ok) continue;
      const value = await response.json();
      if (value?.apiKey && value?.projectId) return { ...value, appId: value.appId || WEB_APP_ID };
    } catch { /* try the next one */ }
  }
  return null;
}

async function load() {
  if (sdk) return sdk;
  sdk = (async () => {
    const options = await config();
    if (!options) return null;
    const [{ initializeApp }, ai, remote, appCheck] = await Promise.all([
      import(`${SDK}/firebase-app.js`), import(`${SDK}/firebase-ai.js`), import(`${SDK}/firebase-remote-config.js`),
      import(`${SDK}/firebase-app-check.js`)
    ]);
    const app = initializeApp(options);
    startAppCheck(app, appCheck);
    // Remote Config can switch the cloud model off or change it without a deploy.
    const rc = remote.getRemoteConfig(app);
    rc.defaultConfig = { assistant_cloud_enabled: true, assistant_cloud_model: DEFAULT_MODEL };
    rc.settings.minimumFetchIntervalMillis = 3600 * 1000;
    remote.fetchAndActivate(rc).catch(() => {});
    return { app, ai, remote, rc, instance: ai.getAI(app, { backend: new ai.GoogleAIBackend() }) };
  })().catch(() => null);
  return sdk;
}

function startAppCheck(app, appCheck) {
  const local = ["localhost", "127.0.0.1"].includes(location.hostname);
  if (local) self.FIREBASE_APPCHECK_DEBUG_TOKEN = true;
  if (!APP_CHECK_SITE_KEY && !local) return;
  try {
    appCheck.initializeAppCheck(app, {
      provider: new appCheck.ReCaptchaEnterpriseProvider(APP_CHECK_SITE_KEY || "debug"),
      isTokenAutoRefreshEnabled: true
    });
  } catch { /* Gemini then runs unprotected; on-device and keyword reading are unaffected */ }
}

/** Whether Chrome's on-device model can run here, without loading anything. */
export async function onDeviceStatus() {
  try {
    if (!("LanguageModel" in self)) return "unavailable";
    return await self.LanguageModel.availability({ expectedInputs: [{ type: "text", languages: ["en"] }] });
  } catch { return "unavailable"; }
}

/** Whether a Firebase web app is set up for this site. */
export async function isConfigured() { return !!(await load()); }

/**
 * A reader for assistant.interpret, or null when no model may run.
 * `allowCloud` is the passenger's opt-in; on-device reading never leaves the browser.
 */
export async function modelReader({ allowCloud }) {
  const onDevice = (await onDeviceStatus()) === "available";
  const cloud = allowCloud && navigator.onLine;
  if (!onDevice && !cloud) return null;
  const firebase = await load();
  if (!firebase) return null;
  const { ai, remote, rc, instance } = firebase;
  const cloudOn = cloud && remote.getValue(rc, "assistant_cloud_enabled").asBoolean();
  if (!onDevice && !cloudOn) return null;
  const modelName = remote.getValue(rc, "assistant_cloud_model").asString() || DEFAULT_MODEL;
  const mode = onDevice ? (cloudOn ? ai.InferenceMode.PREFER_ON_DEVICE : ai.InferenceMode.ONLY_ON_DEVICE) : ai.InferenceMode.ONLY_IN_CLOUD;
  const key = `${mode}|${modelName}`;
  if (!models.has(key)) {
    models.set(key, ai.getGenerativeModel(instance, {
      mode,
      inCloudParams: {
        model: modelName,
        systemInstruction: MODEL_INSTRUCTIONS,
        generationConfig: { responseMimeType: "application/json", responseJsonSchema: MODEL_SCHEMA, maxOutputTokens: 400, thinkingConfig: { thinkingLevel: ai.ThinkingLevel.MINIMAL } }
      },
      onDeviceParams: {
        createOptions: { expectedInputs: [{ type: "text", languages: ["en"] }], initialPrompts: [{ role: "system", content: MODEL_INSTRUCTIONS }] },
        promptOptions: { responseConstraint: MODEL_SCHEMA }
      }
    }));
  }
  const model = models.get(key);
  return async (text, context) => {
    const result = await model.generateContent(modelPrompt(text, context));
    const source = result.response.inferenceSource;
    return { turn: turnFromModel(JSON.parse(result.response.text())), by: source === ai.InferenceSource.ON_DEVICE ? "onDevice" : "cloud" };
  };
}
