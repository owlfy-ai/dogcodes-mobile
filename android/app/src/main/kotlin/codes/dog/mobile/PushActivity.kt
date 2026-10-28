package codes.dog.mobile

import com.alibaba.sdk.android.push.AndroidPopupActivity
import org.json.JSONObject

class PushActivity : AndroidPopupActivity() {
    override fun onSysNoticeOpened(title: String?, summary: String?, extraMap: Map<String, String>?) {
        openPush(this, JSONObject(extraMap ?: emptyMap<String, String>()).toString())
        finish()
    }
}
