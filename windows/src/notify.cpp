#include "notify.h"

namespace Notifications {

namespace {
struct Entry {
    int id;
    Notice name;
    std::shared_ptr<std::function<void(void*)>> observer;
};
std::vector<Entry>& entries() {
    static auto* list = new std::vector<Entry>();
    return *list;
}
int gNext = 1;
}  // namespace

int add(Notice name, std::function<void(void* object)> observer) {
    int id = gNext++;
    entries().push_back({id, name, std::make_shared<std::function<void(void*)>>(std::move(observer))});
    return id;
}

void remove(int id) {
    auto& list = entries();
    list.erase(std::remove_if(list.begin(), list.end(), [id](const Entry& e) { return e.id == id; }),
               list.end());
}

void post(Notice name, void* object) {
    // A snapshot: an observer may add or remove others while it runs.
    std::vector<std::pair<int, std::shared_ptr<std::function<void(void*)>>>> targets;
    for (auto& e : entries()) {
        if (e.name == name) targets.emplace_back(e.id, e.observer);
    }
    for (auto& [id, observer] : targets) {
        bool stillThere = false;
        for (auto& e : entries()) stillThere = stillThere || e.id == id;
        if (stillThere) (*observer)(object);
    }
}

}  // namespace Notifications
