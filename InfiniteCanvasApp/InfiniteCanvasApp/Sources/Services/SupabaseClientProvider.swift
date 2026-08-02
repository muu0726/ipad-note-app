import Foundation
import Supabase

/// Supabase(Auth / DB / Storage)アクセス用クライアントの生成・保持を担うシングルトン。
///
/// URL / anon key は `SupabaseConfig.plist`(Git 非コミット)から読み込み、ソースにハードコードしない。
/// 設定が無い/空のときは `client == nil`(= 未設定)を返し、アプリはローカルのみで動作する。
/// 認証(#5)・同期(#7)はこの `client` を土台に段階的に導入する。
@MainActor
final class SupabaseClientProvider {
    static let shared = SupabaseClientProvider()

    /// 設定が揃っているときのみ非 nil。呼び出し側は未設定(ローカルのみ)を許容すること。
    let client: SupabaseClient?

    /// Supabase 同期が利用可能か(設定済みか)。
    var isConfigured: Bool { client != nil }

    private init() {
        if let config = SupabaseConfig.loadFromBundle(),
           let url = URL(string: config.url) {
            self.client = SupabaseClient(supabaseURL: url, supabaseKey: config.anonKey)
        } else {
            self.client = nil
        }
    }
}

/// バンドル同梱の `SupabaseConfig.plist` から接続情報を読む。
struct SupabaseConfig {
    let url: String
    let anonKey: String

    /// `SupabaseConfig.plist` を読み、URL と anon key が両方とも非空なら返す。無ければ nil。
    static func loadFromBundle(_ bundle: Bundle = .main) -> SupabaseConfig? {
        guard
            let plistURL = bundle.url(forResource: "SupabaseConfig", withExtension: "plist"),
            let data = try? Data(contentsOf: plistURL),
            let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let url = (dict["SUPABASE_URL"] as? String), !url.isEmpty,
            let anonKey = (dict["SUPABASE_ANON_KEY"] as? String), !anonKey.isEmpty
        else {
            return nil
        }
        return SupabaseConfig(url: url, anonKey: anonKey)
    }
}
