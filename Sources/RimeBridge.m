#import <Foundation/Foundation.h>
#include "rime_api.h"
#include "RimeBridge.h"
static RimeApi *api;
static NSString *sharedPath, *userPath;
bool TTInitializeRime(const char *shared, const char *user) {
    if (api) return true;
    sharedPath = [[NSString alloc] initWithUTF8String:shared];
    userPath = [[NSString alloc] initWithUTF8String:user];
    RIME_STRUCT(RimeTraits, traits);
    traits.shared_data_dir = sharedPath.UTF8String;
    traits.user_data_dir = userPath.UTF8String;
    traits.distribution_name = "TranslateType";
    traits.distribution_code_name = "translate_type";
    traits.distribution_version = "0.1.0";
    traits.app_name = "rime.translate_type";
    traits.min_log_level = 2;
    traits.log_dir = "";
    api = rime_get_api();
    api->setup(&traits);
    api->initialize(&traits);
    api->start_maintenance(False);
    api->join_maintenance_thread();
    return true;
}
uintptr_t TTCreateSession(const char *schema) {
    if (!api) return 0;
    RimeSessionId session = api->create_session();
    if (!api->select_schema(session, schema)) { api->destroy_session(session); return 0; }
    api->set_option(session, "ascii_mode", False);
    // Match our horizontal candidate row: arrows navigate candidates at the
    // input end; Left at the first candidate falls through to the navigator.
    api->set_option(session, "_linear", True);
    return session;
}
void TTDestroySession(uintptr_t s) { if (s && api) api->destroy_session(s); }
bool TTProcessKey(uintptr_t s, int k, int m) {
    if (!s || !api) return false;
    // Up/Down keep selecting candidates, including while editing pinyin.
    // Linear selector fallback is for Left/Right only; at the first item it
    // would otherwise pass Up to the host and unexpectedly move its cursor.
    if (m == 0 && (k == 0xff52 || k == 0xff54)) {
        RIME_STRUCT(RimeContext, context);
        if (api->get_context(s, &context)) {
            BOOL hasCandidates = context.menu.num_candidates > 0;
            int index = context.menu.page_no * context.menu.page_size + context.menu.highlighted_candidate_index;
            api->free_context(&context);
            if (hasCandidates) {
                int next = index + (k == 0xff52 ? -1 : 1);
                if (next >= 0) api->highlight_candidate(s, (size_t)next);
                return true; // Consume the boundary key even when no item exists.
            }
        }
    }
    return api->process_key(s, k, m);
}
bool TTSelectCandidate(uintptr_t s, int i) { return s && api->select_candidate_on_current_page(s, i); }
void TTCommitComposition(uintptr_t s) { if (s) api->commit_composition(s); }
void TTClearComposition(uintptr_t s) { if (s) api->clear_composition(s); }
static NSString *str(const char *s) { return s ? [NSString stringWithUTF8String:s] ?: @"" : @""; }
// Rime offsets count UTF-8 bytes; AppKit text ranges count UTF-16 code units.
static NSUInteger textOffset(const char *text, int byteOffset) {
    if (!text || byteOffset <= 0) return 0;
    size_t count = MIN((size_t)byteOffset, strlen(text));
    return [[NSString alloc] initWithBytes:text length:count encoding:NSUTF8StringEncoding].length;
}
char *TTSnapshot(uintptr_t s) {
    RIME_STRUCT(RimeContext, context);
    NSMutableArray *candidates = [NSMutableArray array];
    NSString *preedit = @"", *preview = @"", *commitText = @"";
    NSString *input = str(api->get_input(s));
    int highlighted = 0, page = 0;
    NSUInteger caret = 0, selectionStart = 0, selectionEnd = 0;
    BOOL lastPage = YES;
    if (api->get_context(s, &context)) {
        preedit = str(context.composition.preedit);
        caret = textOffset(context.composition.preedit, context.composition.cursor_pos);
        selectionStart = textOffset(context.composition.preedit, context.composition.sel_start);
        selectionEnd = textOffset(context.composition.preedit, context.composition.sel_end);
        preview = str(context.commit_text_preview);
        highlighted = context.menu.highlighted_candidate_index;
        page = context.menu.page_no;
        lastPage = context.menu.is_last_page;
        for (int i=0; i<context.menu.num_candidates; i++) [candidates addObject:str(context.menu.candidates[i].text)];
        api->free_context(&context);
    }
    RIME_STRUCT(RimeCommit, commit);
    if (api->get_commit(s, &commit)) { commitText = str(commit.text); api->free_commit(&commit); }
    NSDictionary *snapshot = @{@"preedit":preedit, @"input":input, @"preview":preview, @"candidates":candidates,
                              @"caret":@(caret), @"selectionStart":@(selectionStart), @"selectionEnd":@(selectionEnd),
                              @"highlighted":@(highlighted), @"page":@(page), @"lastPage":@(lastPage), @"commit":commitText};
    NSData *data = [NSJSONSerialization dataWithJSONObject:snapshot options:0 error:nil];
    return strdup([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
}
void TTFreeString(char *s) { free(s); }
